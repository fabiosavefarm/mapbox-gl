part of mapbox_gl_web;

const String _defaultMapboxGlJsVersion = 'v3.25.0';
const String _defaultMapboxGlJsUrl =
    'https://api.mapbox.com/mapbox-gl-js/$_defaultMapboxGlJsVersion/mapbox-gl.js';
const String _defaultMapboxGlCssUrl =
    'https://api.mapbox.com/mapbox-gl-js/$_defaultMapboxGlJsVersion/mapbox-gl.css';

@JS('globalThis')
external JSObject get _globalThis;

@JS('JSON.stringify')
external JSString? _jsonStringify(JSAny? value);

Future<void>? _mapboxGlResourcesLoad;
Future<void>? _mapboxGlCssLoad;
bool? _mapboxGlWebDebugEnabledCache;

bool get _mapboxGlWebDebugEnabled {
  final cached = _mapboxGlWebDebugEnabledCache;
  if (cached != null) return cached;

  final search = web.window.location.search;
  final enabled = kDebugMode ||
      search.contains('mapbox_gl_web_debug=1') ||
      search.contains('mapbox_gl_web_debug=true') ||
      search.contains('mapbox_gl_debug=1') ||
      search.contains('mapbox_gl_debug=true');
  _mapboxGlWebDebugEnabledCache = enabled;
  return enabled;
}

String _mapboxGlRendererLabel() {
  if (!kIsWeb) return 'non-web';
  if (isSkwasm) return 'skwasm';
  if (isCanvasKit) return 'canvaskit';
  if (kIsWasm) return 'wasm-unknown';
  return 'js';
}

String _mapboxGlVersionOrUnknown() {
  final mapboxgl = _globalThis['mapboxgl'];
  if (mapboxgl == null) return 'unloaded';
  final version = (mapboxgl as JSObject)['version'];
  if (version is JSString) return version.toDart;
  return 'unknown';
}

void _logMapboxWebDebug(
  String stage, [
  Map<String, Object?> details = const <String, Object?>{},
]) {
  if (!_mapboxGlWebDebugEnabled) return;
  final payload = <String>[
    'stage=$stage',
    'renderer=${_mapboxGlRendererLabel()}',
    'wasm=$kIsWasm',
    'mapboxGl=${_mapboxGlVersionOrUnknown()}',
    for (final entry in details.entries) '${entry.key}=${entry.value}',
  ].join(' ');
  print('[mapbox_gl_web] $payload');
}

Never _throwMapboxWebError(
  String stage,
  Object error,
  StackTrace stackTrace, [
  Map<String, Object?> details = const <String, Object?>{},
]) {
  final payload = <String>[
    'stage=$stage',
    'renderer=${_mapboxGlRendererLabel()}',
    'wasm=$kIsWasm',
    'mapboxGl=${_mapboxGlVersionOrUnknown()}',
    for (final entry in details.entries) '${entry.key}=${entry.value}',
  ].join(' ');
  print('[mapbox_gl_web] ERROR $payload error=$error');
  if (_mapboxGlWebDebugEnabled) {
    print(stackTrace);
  }
  Error.throwWithStackTrace(error, stackTrace);
}

bool _isMapboxGlLoaded() => _globalThis.has('mapboxgl');

JSObject _getMapboxGlOrThrow() {
  final mapboxgl = _globalThis['mapboxgl'];
  if (mapboxgl == null) {
    throw StateError(
      'Mapbox GL JS not found. Load it in `web/index.html` or let the plugin inject it at runtime.',
    );
  }
  return mapboxgl as JSObject;
}

void _setMapboxAccessToken(String accessToken) {
  final mapboxgl = _getMapboxGlOrThrow();
  mapboxgl['accessToken'] = accessToken.toJS;
}

JSObject _newMapboxGlObject(String constructorName, [JSAny? arg1]) {
  final mapboxgl = _getMapboxGlOrThrow();
  final ctorAny = mapboxgl[constructorName];
  if (ctorAny == null) {
    throw StateError('`mapboxgl.$constructorName` is not available.');
  }
  final ctor = ctorAny as JSFunction;
  return ctor.callAsConstructor<JSObject>(arg1);
}

Future<void> _ensureMapboxGlCssLoaded(
    {String cssUrl = _defaultMapboxGlCssUrl}) {
  return _mapboxGlCssLoad ??= () async {
    _logMapboxWebDebug('ensure-css:start', <String, Object?>{'cssUrl': cssUrl});
    final existing = web.document.querySelectorAll('link[rel="stylesheet"]');
    for (var i = 0; i < existing.length; i++) {
      final node = existing.item(i);
      if (node == null) continue;
      final link = node as web.HTMLLinkElement;
      if (link.href == cssUrl || link.href.contains('mapbox-gl.css')) {
        _logMapboxWebDebug(
          'ensure-css:reuse',
          <String, Object?>{'cssUrl': cssUrl},
        );
        return;
      }
    }

    final completer = Completer<void>();
    final link = web.HTMLLinkElement()
      ..rel = 'stylesheet'
      ..href = cssUrl;

    late final JSFunction onLoad;
    late final JSFunction onError;

    onLoad = ((web.Event _) {
      link.removeEventListener('load', onLoad);
      link.removeEventListener('error', onError);
      completer.complete();
    }).toJS;

    onError = ((web.Event _) {
      link.removeEventListener('load', onLoad);
      link.removeEventListener('error', onError);
      completer.completeError(
        StateError('Failed to load Mapbox GL CSS from $cssUrl'),
      );
    }).toJS;

    link.addEventListener('load', onLoad);
    link.addEventListener('error', onError);

    (web.document.head ?? web.document.documentElement)!.appendChild(link);
    await completer.future;
    _logMapboxWebDebug('ensure-css:ready', <String, Object?>{'cssUrl': cssUrl});
  }();
}

Future<void> _ensureMapboxGlJsLoaded({String jsUrl = _defaultMapboxGlJsUrl}) {
  return _mapboxGlResourcesLoad ??= () async {
    if (_isMapboxGlLoaded()) {
      _logMapboxWebDebug(
        'ensure-js:reuse',
        <String, Object?>{'jsUrl': jsUrl},
      );
      return;
    }

    _logMapboxWebDebug('ensure-js:start', <String, Object?>{'jsUrl': jsUrl});

    final completer = Completer<void>();
    final script = web.HTMLScriptElement()
      ..src = jsUrl
      ..type = 'text/javascript'
      ..async = true;

    late final JSFunction onLoad;
    late final JSFunction onError;

    onLoad = ((web.Event _) {
      script.removeEventListener('load', onLoad);
      script.removeEventListener('error', onError);
      completer.complete();
    }).toJS;

    onError = ((web.Event _) {
      script.removeEventListener('load', onLoad);
      script.removeEventListener('error', onError);
      completer.completeError(
        StateError('Failed to load Mapbox GL JS from $jsUrl'),
      );
    }).toJS;

    script.addEventListener('load', onLoad);
    script.addEventListener('error', onError);

    (web.document.head ?? web.document.documentElement)!.appendChild(script);
    await completer.future;

    if (!_isMapboxGlLoaded()) {
      throw StateError(
        'Loaded Mapbox GL JS script, but `globalThis.mapboxgl` is still missing.',
      );
    }
    _logMapboxWebDebug(
      'ensure-js:ready',
      <String, Object?>{
        'jsUrl': jsUrl,
        'version': _mapboxGlVersionOrUnknown(),
      },
    );
  }();
}

Future<void> _ensureMapboxGlResourcesLoaded({
  String jsUrl = _defaultMapboxGlJsUrl,
  String cssUrl = _defaultMapboxGlCssUrl,
}) async {
  await Future.wait<void>([
    _ensureMapboxGlCssLoaded(cssUrl: cssUrl),
    _ensureMapboxGlJsLoaded(jsUrl: jsUrl),
  ]);
}

JSAny? _jsify(dynamic value) {
  if (value == null) return null;
  if (value is String) return value.toJS;
  if (value is num) return value.toJS;
  if (value is bool) return value.toJS;

  if (value is List) {
    final jsList = <JSAny?>[];
    for (final item in value) {
      jsList.add(_jsify(item));
    }
    return jsList.toJS;
  }

  if (value is Map) {
    final obj = JSObject();
    for (final entry in value.entries) {
      final key = entry.key;
      if (key is! String) {
        throw ArgumentError.value(
          key,
          'value',
          'Only Map<String, *> can be converted to a JS object.',
        );
      }
      obj[key] = _jsify(entry.value);
    }
    return obj;
  }

  throw ArgumentError.value(
    value,
    'value',
    'Unsupported value for JS interop conversion.',
  );
}

dynamic _dartifyViaJson(JSAny? value) {
  final jsonString = _jsonStringify(value)?.toDart;
  if (jsonString == null) return null;
  return jsonDecode(jsonString);
}
