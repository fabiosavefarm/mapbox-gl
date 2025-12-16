part of mapbox_gl_web;

const String _defaultMapboxGlJsUrl =
    'https://api.mapbox.com/mapbox-gl-js/v2.8.2/mapbox-gl.js';
const String _defaultMapboxGlCssUrl =
    'https://api.mapbox.com/mapbox-gl-js/v2.8.2/mapbox-gl.css';

@JS('globalThis')
external JSObject get _globalThis;

@JS('JSON.stringify')
external JSString? _jsonStringify(JSAny? value);

Future<void>? _mapboxGlResourcesLoad;
Future<void>? _mapboxGlCssLoad;

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
    final existing = web.document.querySelectorAll('link[rel="stylesheet"]');
    for (var i = 0; i < existing.length; i++) {
      final node = existing.item(i);
      if (node == null) continue;
      final link = node as web.HTMLLinkElement;
      if (link.href == cssUrl || link.href.contains('mapbox-gl.css')) {
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
  }();
}

Future<void> _ensureMapboxGlJsLoaded({String jsUrl = _defaultMapboxGlJsUrl}) {
  return _mapboxGlResourcesLoad ??= () async {
    if (_isMapboxGlLoaded()) return;

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
