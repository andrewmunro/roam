extends Node
## Prioritised HTTP fetcher with a concurrency limit, retries, an in-memory LRU
## and a persistent cache in user:// (IndexedDB when running on the web).

const MAX_CONCURRENT := 4
const MAX_RETRIES := 3
const MAX_RATE_RETRIES := 6  ## a 429 (rate limited) keeps trying for longer, more slowly
const MEMORY_CACHE_BYTES := 64 * 1024 * 1024
const DISK_CACHE_DIR := "user://cache"

## url -> {priority, callbacks: Array[Callable], disk: bool, key, headers, attempts}
var _pending := {}
var _queue: Array[String] = []
var _idle: Array[HTTPRequest] = []
var _active := 0
var _memory := {}  # url -> PackedByteArray (insertion order is LRU order)
var _memory_bytes := 0


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(DISK_CACHE_DIR)


## Calls `callback(ok: bool, body: PackedByteArray)` once the URL is fetched.
## Lower priority values are fetched first. `cache_key` names the disk copy when the
## URL itself changes over time (versioned tile URLs); by default the URL does.
func request(url: String, callback: Callable, priority := 0.0, disk_cache := true,
		headers := PackedStringArray(), cache_key := "") -> void:
	var key := url if cache_key.is_empty() else cache_key
	if _memory.has(url):
		var body: PackedByteArray = _memory[url]
		_memory.erase(url)
		_memory[url] = body
		callback.call_deferred(true, body)
		return
	if disk_cache:
		var cached := _read_disk(key)
		if cached.is_empty() and key != url:
			cached = _read_disk(url)  # cached before it had a key of its own: move it over
			if not cached.is_empty():
				_write_disk(key, cached)
		if not cached.is_empty():
			_remember(url, cached)
			callback.call_deferred(true, cached)
			return
	if _pending.has(url):
		var entry: Dictionary = _pending[url]
		entry.callbacks.append(callback)
		entry.priority = minf(entry.priority, priority)
		return
	_pending[url] = {
		priority = priority, callbacks = [callback], disk = disk_cache, key = key,
		headers = headers, attempts = 0,
	}
	_queue.append(url)
	_pump()


func set_priority(url: String, priority: float) -> void:
	if _pending.has(url):
		_pending[url].priority = priority


## Drops queued (not yet started) requests; their callbacks get ok=false.
func cancel_queued() -> void:
	for url in _queue:
		var entry: Dictionary = _pending[url]
		_pending.erase(url)
		for cb: Callable in entry.callbacks:
			cb.call_deferred(false, PackedByteArray())
	_queue.clear()


func _pump() -> void:
	if _queue.is_empty() or _active >= MAX_CONCURRENT:
		return
	_queue.sort_custom(func(a: String, b: String) -> bool:
		return _pending[a].priority < _pending[b].priority)
	while not _queue.is_empty() and _active < MAX_CONCURRENT:
		_start(_queue.pop_front())


func _start(url: String) -> void:
	var http: HTTPRequest
	if _idle.is_empty():
		http = HTTPRequest.new()
		http.timeout = 30.0
		http.accept_gzip = true
		add_child(http)
	else:
		http = _idle.pop_back()
	_active += 1
	var entry: Dictionary = _pending[url]
	http.request_completed.connect(_on_completed.bind(http, url), CONNECT_ONE_SHOT)
	var err := http.request(url, entry.headers)
	if err != OK:
		http.request_completed.disconnect(_on_completed)
		_on_completed(HTTPRequest.RESULT_CANT_CONNECT, 0, PackedStringArray(), PackedByteArray(), http, url)


func _on_completed(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray,
		http: HTTPRequest, url: String) -> void:
	_active -= 1
	_idle.append(http)
	var entry: Dictionary = _pending[url]
	var ok := result == HTTPRequest.RESULT_SUCCESS and code >= 200 and code < 300
	# 404 is a definitive answer (e.g. no tile there); everything else is retried.
	var limited := code == 429
	if not ok and code != 404 and entry.attempts < (MAX_RATE_RETRIES if limited else MAX_RETRIES):
		entry.attempts += 1
		var wait := (4.0 if limited else 0.5) * pow(2.0, entry.attempts)
		get_tree().create_timer(wait).timeout.connect(func() -> void:
			_queue.append(url)
			_pump())
		_pump()
		return
	_pending.erase(url)
	if ok:
		_remember(url, body)
		if entry.disk:
			_write_disk(entry.key, body)
	else:
		push_warning("Fetch failed (%d/%d): %s" % [result, code, url])
	for cb: Callable in entry.callbacks:
		cb.call(ok, body)
	_pump()


func _remember(url: String, body: PackedByteArray) -> void:
	_memory[url] = body
	_memory_bytes += body.size()
	while _memory_bytes > MEMORY_CACHE_BYTES and _memory.size() > 1:
		var oldest: String = _memory.keys()[0]
		_memory_bytes -= (_memory[oldest] as PackedByteArray).size()
		_memory.erase(oldest)


func _disk_path(key: String) -> String:
	return DISK_CACHE_DIR.path_join(key.md5_text() + ".bin")


## The disk copy for a cache key (a URL or a request's cache_key); empty if none.
func _read_disk(key: String) -> PackedByteArray:
	var path := _disk_path(key)
	if not FileAccess.file_exists(path):
		return PackedByteArray()
	return FileAccess.get_file_as_bytes(path)


func _write_disk(key: String, body: PackedByteArray) -> void:
	var f := FileAccess.open(_disk_path(key), FileAccess.WRITE)
	if f:
		f.store_buffer(body)
