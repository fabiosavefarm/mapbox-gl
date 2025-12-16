part of mapbox_gl_web;

class MapboxWebGlPlatform extends MapboxGlPlatform
    implements MapboxMapOptionsSink {
  static const String _viewTypePrefix = 'plugins.flutter.io/mapbox_gl_';
  static const String _defaultStyle = MapboxStyles.MAPBOX_STREETS;
  static const int _defaultMaxZoom = 22;

  late web.HTMLDivElement _mapElement;
  late Map<String, dynamic> _creationParams;

  JSObject? _map;
  bool _mapReady = false;

  bool _dragEnabled = true;
  dynamic _draggedFeatureId;
  LatLng? _dragOrigin;
  LatLng? _dragPrevious;

  final _interactiveFeatureLayerIds = <String>{};

  bool _trackCameraPosition = false;
  LatLng? _myLastLocation;

  JSObject? _geolocateControl;

  JSObject? _navigationControl;
  String? _navigationControlPosition;

  web.ResizeObserver? _resizeObserver;
  Timer? _resizeObserverDebounce;

  final _geoJsonBySourceId = <String, Map<String, dynamic>>{};
  final _imageSourceDataUrlById = <String, String>{};

  late final JSFunction _onStyleLoadedJs = ((JSAny? _) {
    _onStyleLoaded();
  }).toJS;

  late final JSFunction _onMapClickJs = ((JSAny? e) {
    _onMapClick(e);
  }).toJS;

  late final JSFunction _onMapLongClickJs = ((JSAny? e) {
    _onMapLongClick(e);
  }).toJS;

  late final JSFunction _onCameraMoveStartedJs = ((JSAny? _) {
    onCameraMoveStartedPlatform(null);
  }).toJS;

  late final JSFunction _onCameraMoveJs = ((JSAny? _) {
    _onCameraMove();
  }).toJS;

  late final JSFunction _onCameraIdleJs = ((JSAny? _) {
    _onCameraIdle();
  }).toJS;

  late final JSFunction _onResizeEventJs = ((JSAny? _) {
    _onMapResize();
  }).toJS;

  late final JSFunction _onStyleImageMissingJs = ((JSAny? e) {
    _loadMissingImageFromAssets(e);
  }).toJS;

  late final JSFunction _onMouseDownJs = ((JSAny? e) {
    _onMouseDown(e);
  }).toJS;

  late final JSFunction _onMouseUpJs = ((JSAny? e) {
    _onMouseUp(e);
  }).toJS;

  late final JSFunction _onMouseMoveJs = ((JSAny? e) {
    _onMouseMove(e);
  }).toJS;

  late final JSFunction _onMouseEnterFeatureJs = ((JSAny? _) {
    _onMouseEnterFeature();
  }).toJS;

  late final JSFunction _onMouseLeaveFeatureJs = ((JSAny? _) {
    _onMouseLeaveFeature();
  }).toJS;

  JSObject get _mapOrThrow =>
      _map ?? (throw StateError('Mapbox GL map is not initialized yet.'));

  @override
  Widget buildView(
    Map<String, dynamic> creationParams,
    OnPlatformViewCreatedCallback onPlatformViewCreated,
    Set<Factory<OneSequenceGestureRecognizer>>? gestureRecognizers,
  ) {
    _creationParams = creationParams;
    final identifier = hashCode;
    _registerViewFactory(onPlatformViewCreated, identifier);
    return HtmlElementView(viewType: '$_viewTypePrefix$identifier');
  }

  void _registerViewFactory(
    Function(int) callback,
    int identifier,
  ) {
    ui_web.platformViewRegistry.registerViewFactory(
      '$_viewTypePrefix$identifier',
      (int viewId) {
        _mapElement = web.HTMLDivElement()
          ..style.position = 'absolute'
          ..style.top = '0'
          ..style.bottom = '0'
          ..style.left = '0'
          ..style.right = '0'
          ..style.width = '100%'
          ..style.height = '100%';
        callback(viewId);
        return _mapElement;
      },
    );
  }

  @override
  void dispose() {
    super.dispose();
    _resizeObserverDebounce?.cancel();
    _resizeObserver?.disconnect();

    for (final url in _imageSourceDataUrlById.values) {
      if (url.startsWith('blob:')) {
        try {
          web.URL.revokeObjectURL(url);
        } catch (_) {
          // ignore
        }
      }
    }
    _imageSourceDataUrlById.clear();

    try {
      _mapOrThrow.callMethodVarArgs('remove'.toJS);
    } catch (_) {
      // ignore
    }
  }

  @override
  Future<void> initPlatform(int id) async {
    _dragEnabled = _creationParams['dragEnabled'] ?? true;

    final jsUrl =
        (_creationParams['mapboxGlJsUrl'] as String?) ?? _defaultMapboxGlJsUrl;
    final cssUrl = (_creationParams['mapboxGlCssUrl'] as String?) ??
        _defaultMapboxGlCssUrl;
    await _ensureMapboxGlResourcesLoaded(jsUrl: jsUrl, cssUrl: cssUrl);

    final accessToken = _creationParams['accessToken'];
    if (accessToken is String && accessToken.isNotEmpty) {
      _setMapboxAccessToken(accessToken);
    }

    final initialCamera = _creationParams['initialCameraPosition'];
    if (initialCamera is! Map) {
      throw StateError('Missing `initialCameraPosition` for Mapbox GL web.');
    }

    final target = initialCamera['target'];
    if (target is! List || target.length != 2) {
      throw StateError('Invalid `initialCameraPosition.target` payload.');
    }

    final center = <JSAny?>[
      (target[1] as num).toJS,
      (target[0] as num).toJS,
    ].toJS;

    final mapOptions = JSObject()
      ..['container'] = _mapElement
      ..['style'] = _defaultStyle.toJS
      ..['center'] = center
      ..['zoom'] = (initialCamera['zoom'] as num?)?.toJS
      ..['bearing'] = (initialCamera['bearing'] as num?)?.toJS
      ..['pitch'] = (initialCamera['tilt'] as num?)?.toJS
      ..['preserveDrawingBuffer'] = true.toJS;

    _map = _newMapboxGlObject('Map', mapOptions);

    _mapOn('load', _onStyleLoadedJs);
    _mapOn('click', _onMapClickJs);
    // Long click is not available in Mapbox GL JS; map it to double-click.
    _mapOn('dblclick', _onMapLongClickJs);
    _mapOn('movestart', _onCameraMoveStartedJs);
    _mapOn('move', _onCameraMoveJs);
    _mapOn('moveend', _onCameraIdleJs);
    _mapOn('resize', _onResizeEventJs);
    _mapOn('styleimagemissing', _onStyleImageMissingJs);

    if (_dragEnabled) {
      _mapOn('mouseup', _onMouseUpJs);
      _mapOn('mousemove', _onMouseMoveJs);
    }

    _initResizeObserver();

    final options = _creationParams['options'];
    if (options is Map<String, dynamic>) {
      _applyOptionsUpdate(options);
    }
  }

  void _mapOn(String eventType, JSFunction callback) {
    _mapOrThrow.callMethodVarArgs('on'.toJS, [eventType.toJS, callback]);
  }

  void _mapOnce(String eventType, JSFunction callback) {
    _mapOrThrow.callMethodVarArgs('once'.toJS, [eventType.toJS, callback]);
  }

  void _mapOffLayer(String eventType, String layerId, JSFunction callback) {
    _mapOrThrow.callMethodVarArgs(
      'off'.toJS,
      [eventType.toJS, layerId.toJS, callback],
    );
  }

  void _mapOnLayer(String eventType, String layerId, JSFunction callback) {
    _mapOrThrow.callMethodVarArgs(
      'on'.toJS,
      [eventType.toJS, layerId.toJS, callback],
    );
  }

  void _initResizeObserver() {
    _resizeObserver?.disconnect();
    _resizeObserverDebounce?.cancel();

    _resizeObserver = web.ResizeObserver(((JSAny? _, JSAny? __) {
      _resizeObserverDebounce?.cancel();
      _resizeObserverDebounce = Timer(const Duration(milliseconds: 50), () {
        _onMapResize();
      });
    }).toJS);

    _resizeObserver!.observe(_mapElement);
  }

  void _applyOptionsUpdate(Map<String, dynamic> options) {
    if (options.containsKey('cameraTargetBounds')) {
      final bounds = options['cameraTargetBounds'][0];
      if (bounds == null) {
        setCameraTargetBounds(null);
      } else {
        setCameraTargetBounds(
          LatLngBounds(
            southwest: LatLng(bounds[0][0], bounds[0][1]),
            northeast: LatLng(bounds[1][0], bounds[1][1]),
          ),
        );
      }
    }
    if (options.containsKey('compassEnabled')) {
      setCompassEnabled(options['compassEnabled']);
    }
    if (options.containsKey('styleString')) {
      setStyleString(options['styleString']);
    }
    if (options.containsKey('minMaxZoomPreference')) {
      setMinMaxZoomPreference(
        options['minMaxZoomPreference'][0],
        options['minMaxZoomPreference'][1],
      );
    }
    if (options['rotateGesturesEnabled'] != null &&
        options['scrollGesturesEnabled'] != null &&
        options['tiltGesturesEnabled'] != null &&
        options['zoomGesturesEnabled'] != null &&
        options['doubleClickZoomEnabled'] != null) {
      setGestures(
        rotateGesturesEnabled: options['rotateGesturesEnabled'],
        scrollGesturesEnabled: options['scrollGesturesEnabled'],
        tiltGesturesEnabled: options['tiltGesturesEnabled'],
        zoomGesturesEnabled: options['zoomGesturesEnabled'],
        doubleClickZoomEnabled: options['doubleClickZoomEnabled'],
      );
    }

    if (options.containsKey('trackCameraPosition')) {
      setTrackCameraPosition(options['trackCameraPosition']);
    }

    if (options.containsKey('myLocationEnabled')) {
      setMyLocationEnabled(options['myLocationEnabled']);
    }
    if (options.containsKey('myLocationTrackingMode')) {
      // Should not be invoked before setMyLocationEnabled().
      setMyLocationTrackingMode(options['myLocationTrackingMode']);
    }
    if (options.containsKey('myLocationRenderMode')) {
      setMyLocationRenderMode(options['myLocationRenderMode']);
    }
    if (options.containsKey('logoViewMargins')) {
      setLogoViewMargins(
          options['logoViewMargins'][0], options['logoViewMargins'][1]);
    }
    if (options.containsKey('compassViewPosition')) {
      final position =
          CompassViewPosition.values[options['compassViewPosition']];
      setCompassAlignment(position);
    }
    if (options.containsKey('compassViewMargins')) {
      setCompassViewMargins(
        options['compassViewMargins'][0],
        options['compassViewMargins'][1],
      );
    }
    if (options.containsKey('attributionButtonPosition')) {
      final position = AttributionButtonPosition
          .values[options['attributionButtonPosition']];
      setAttributionButtonAlignment(position);
    }
    if (options.containsKey('attributionButtonMargins')) {
      setAttributionButtonMargins(
        options['attributionButtonMargins'][0],
        options['attributionButtonMargins'][1],
      );
    }
  }

  CameraPosition? _getCameraPosition() {
    if (!_trackCameraPosition) return null;
    final center = _mapOrThrow.callMethodVarArgs<JSObject>('getCenter'.toJS);
    final lat = (center['lat'] as JSNumber).toDartDouble;
    final lng = (center['lng'] as JSNumber).toDartDouble;
    final bearing =
        _mapOrThrow.callMethodVarArgs<JSNumber>('getBearing'.toJS).toDartDouble;
    final pitch =
        _mapOrThrow.callMethodVarArgs<JSNumber>('getPitch'.toJS).toDartDouble;
    final zoom =
        _mapOrThrow.callMethodVarArgs<JSNumber>('getZoom'.toJS).toDartDouble;
    return CameraPosition(
      bearing: bearing,
      target: LatLng(lat, lng),
      tilt: pitch,
      zoom: zoom,
    );
  }

  void _onStyleLoaded() {
    _mapReady = true;
    _onMapResize();
    onMapStyleLoadedPlatform(null);
  }

  void _onMapResize() {
    Timer(Duration.zero, () {
      final container =
          _mapOrThrow.callMethodVarArgs<web.HTMLElement>('getContainer'.toJS);
      final canvas = _mapOrThrow
          .callMethodVarArgs<web.HTMLCanvasElement>('getCanvas'.toJS);
      final widthMismatch = canvas.clientWidth != container.clientWidth;
      final heightMismatch = canvas.clientHeight != container.clientHeight;
      if (widthMismatch || heightMismatch) {
        _mapOrThrow.callMethodVarArgs('resize'.toJS);
      }
    });
  }

  void _onMapClick(JSAny? event) {
    final e = event as JSObject;
    final point = e['point'] as JSObject;
    final lngLat = e['lngLat'] as JSObject;

    final pointDart = Point<double>(
      (point['x'] as JSNumber).toDartDouble,
      (point['y'] as JSNumber).toDartDouble,
    );
    final latLngDart = LatLng(
      (lngLat['lat'] as JSNumber).toDartDouble,
      (lngLat['lng'] as JSNumber).toDartDouble,
    );

    dynamic id;
    if (_interactiveFeatureLayerIds.isNotEmpty) {
      final options = JSObject()
        ..['layers'] = _interactiveFeatureLayerIds
            .map((l) => l.toJS)
            .toList(growable: false)
            .toJS;

      final queryPoint = <JSAny?>[
        (point['x'] as JSNumber),
        (point['y'] as JSNumber),
      ].toJS;

      final features = _mapOrThrow.callMethodVarArgs<JSArray<JSAny?>>(
        'queryRenderedFeatures'.toJS,
        [queryPoint, options],
      );

      if (features.length > 0) {
        final first = features[0] as JSObject;
        id = _dartifyViaJson(first['id']);
      }
    }

    final payload = <String, dynamic>{
      'point': pointDart,
      'latLng': latLngDart,
      if (id != null) 'id': id,
    };

    if (id != null) {
      onFeatureTappedPlatform(payload);
    } else {
      onMapClickPlatform(payload);
    }
  }

  void _onMapLongClick(JSAny? event) {
    final e = event as JSObject;
    final point = e['point'] as JSObject;
    final lngLat = e['lngLat'] as JSObject;

    onMapLongClickPlatform({
      'point': Point<double>(
        (point['x'] as JSNumber).toDartDouble,
        (point['y'] as JSNumber).toDartDouble,
      ),
      'latLng': LatLng(
        (lngLat['lat'] as JSNumber).toDartDouble,
        (lngLat['lng'] as JSNumber).toDartDouble,
      ),
    });
  }

  void _onCameraMove() {
    final camera = _getCameraPosition();
    if (camera != null) {
      onCameraMovePlatform(camera);
    }
  }

  void _onCameraIdle() {
    onCameraIdlePlatform(_getCameraPosition());
  }

  Future<void> _loadMissingImageFromAssets(JSAny? event) async {
    final e = event as JSObject;
    final idAny = e['id'];
    final imageId = (idAny as JSString?)?.toDart;
    if (imageId == null || imageId.isEmpty) return;

    final bytes = await rootBundle.load(imageId);
    await addImage(imageId, bytes.buffer.asUint8List());
  }

  void _onMouseDown(JSAny? event) {
    final e = event as JSObject;
    final featuresAny = e['features'];
    if (featuresAny == null) return;

    final features = featuresAny as JSArray<JSAny?>;
    if (features.length == 0) return;
    final feature = features[0] as JSObject;

    final propertiesAny = feature['properties'];
    final properties = propertiesAny == null ? null : propertiesAny as JSObject;
    final draggable = properties?['draggable'];
    final isDraggable = (draggable as JSBoolean?)?.toDart ?? false;
    if (!isDraggable) return;

    // Prevent the default map drag behavior.
    e.callMethodVarArgs('preventDefault'.toJS);

    _draggedFeatureId = _dartifyViaJson(feature['id']);
    _mapOrThrow
        .callMethodVarArgs<web.HTMLCanvasElement>('getCanvas'.toJS)
        .style
        .cursor = 'grabbing';

    final lngLat = e['lngLat'] as JSObject;
    _dragOrigin = LatLng(
      (lngLat['lat'] as JSNumber).toDartDouble,
      (lngLat['lng'] as JSNumber).toDartDouble,
    );

    if (_draggedFeatureId == null) return;

    final point = e['point'] as JSObject;
    final current = LatLng(
      (lngLat['lat'] as JSNumber).toDartDouble,
      (lngLat['lng'] as JSNumber).toDartDouble,
    );

    onFeatureDraggedPlatform({
      'id': _draggedFeatureId,
      'point': Point<double>(
        (point['x'] as JSNumber).toDartDouble,
        (point['y'] as JSNumber).toDartDouble,
      ),
      'origin': _dragOrigin,
      'current': current,
      'delta': const LatLng(0, 0),
      'eventType': 'start',
    });
  }

  void _onMouseUp(JSAny? event) {
    if (_draggedFeatureId != null && _dragOrigin != null) {
      final e = event as JSObject;
      final point = e['point'] as JSObject;
      final lngLat = e['lngLat'] as JSObject;
      final current = LatLng(
        (lngLat['lat'] as JSNumber).toDartDouble,
        (lngLat['lng'] as JSNumber).toDartDouble,
      );
      onFeatureDraggedPlatform({
        'id': _draggedFeatureId,
        'point': Point<double>(
          (point['x'] as JSNumber).toDartDouble,
          (point['y'] as JSNumber).toDartDouble,
        ),
        'origin': _dragOrigin,
        'current': current,
        'delta': current - (_dragPrevious ?? _dragOrigin!),
        'eventType': 'end',
      });
    }

    _draggedFeatureId = null;
    _dragPrevious = null;
    _dragOrigin = null;
    _mapOrThrow
        .callMethodVarArgs<web.HTMLCanvasElement>('getCanvas'.toJS)
        .style
        .cursor = '';
  }

  void _onMouseMove(JSAny? event) {
    if (_draggedFeatureId == null || _dragOrigin == null) return;
    final e = event as JSObject;
    final point = e['point'] as JSObject;
    final lngLat = e['lngLat'] as JSObject;
    final current = LatLng(
      (lngLat['lat'] as JSNumber).toDartDouble,
      (lngLat['lng'] as JSNumber).toDartDouble,
    );
    onFeatureDraggedPlatform({
      'id': _draggedFeatureId,
      'point': Point<double>(
        (point['x'] as JSNumber).toDartDouble,
        (point['y'] as JSNumber).toDartDouble,
      ),
      'origin': _dragOrigin,
      'current': current,
      'delta': current - (_dragPrevious ?? _dragOrigin!),
      'eventType': 'drag',
    });
    _dragPrevious = current;
  }

  void _onMouseEnterFeature() {
    if (_draggedFeatureId != null) return;
    _mapOrThrow
        .callMethodVarArgs<web.HTMLCanvasElement>('getCanvas'.toJS)
        .style
        .cursor = 'pointer';
  }

  void _onMouseLeaveFeature() {
    _mapOrThrow
        .callMethodVarArgs<web.HTMLCanvasElement>('getCanvas'.toJS)
        .style
        .cursor = '';
  }

  void _onCameraTrackingChanged(bool isTracking) {
    if (isTracking) {
      onCameraTrackingChangedPlatform(MyLocationTrackingMode.Tracking);
    } else {
      onCameraTrackingChangedPlatform(MyLocationTrackingMode.None);
    }
  }

  void _onCameraTrackingDismissed() {
    onCameraTrackingDismissedPlatform(null);
  }

  void _removeGeolocateControl() {
    if (_geolocateControl == null) return;
    _mapOrThrow.callMethodVarArgs('removeControl'.toJS, [_geolocateControl!]);
    _geolocateControl = null;
  }

  void _addGeolocateControl({required bool trackUserLocation}) {
    _removeGeolocateControl();

    final positionOptions = JSObject()..['enableHighAccuracy'] = true.toJS;
    final options = JSObject()
      ..['positionOptions'] = positionOptions
      ..['trackUserLocation'] = trackUserLocation.toJS
      ..['showAccuracyCircle'] = true.toJS
      ..['showUserLocation'] = true.toJS;

    _geolocateControl = _newMapboxGlObject('GeolocateControl', options);

    final onGeolocate = ((JSAny? event) {
      final e = event as JSObject;
      final coords = e['coords'] as JSObject?;
      if (coords == null) return;

      final latAny = coords['latitude'];
      final lngAny = coords['longitude'];
      if (latAny == null || lngAny == null) return;

      final lat = (latAny as JSNumber).toDartDouble;
      final lng = (lngAny as JSNumber).toDartDouble;
      _myLastLocation = LatLng(lat, lng);

      double? _doubleOrNull(JSAny? v) =>
          v == null ? null : (v as JSNumber).toDartDouble;

      final timestampAny = e['timestamp'];
      final timestampMs = (timestampAny as JSNumber?)?.toDartDouble;

      onUserLocationUpdatedPlatform(
        UserLocation(
          position: LatLng(lat, lng),
          altitude: _doubleOrNull(coords['altitude']),
          bearing: _doubleOrNull(coords['heading']),
          speed: _doubleOrNull(coords['speed']),
          horizontalAccuracy: _doubleOrNull(coords['accuracy']),
          verticalAccuracy: _doubleOrNull(coords['altitudeAccuracy']),
          heading: null,
          timestamp: timestampMs == null
              ? DateTime.now()
              : DateTime.fromMillisecondsSinceEpoch(timestampMs.round()),
        ),
      );
    }).toJS;

    final onTrackStart = ((JSAny? _) {
      _onCameraTrackingChanged(true);
    }).toJS;

    final onTrackEnd = ((JSAny? _) {
      _onCameraTrackingChanged(false);
      _onCameraTrackingDismissed();
    }).toJS;

    _geolocateControl!.callMethodVarArgs(
      'on'.toJS,
      ['geolocate'.toJS, onGeolocate],
    );
    _geolocateControl!.callMethodVarArgs(
      'on'.toJS,
      ['trackuserlocationstart'.toJS, onTrackStart],
    );
    _geolocateControl!.callMethodVarArgs(
      'on'.toJS,
      ['trackuserlocationend'.toJS, onTrackEnd],
    );

    _mapOrThrow.callMethodVarArgs(
      'addControl'.toJS,
      [_geolocateControl!, 'bottom-right'.toJS],
    );
  }

  void _removeNavigationControl() {
    if (_navigationControl == null) return;
    _mapOrThrow.callMethodVarArgs('removeControl'.toJS, [_navigationControl!]);
    _navigationControl = null;
  }

  void _updateNavigationControl({
    bool? compassEnabled,
    CompassViewPosition? position,
  }) {
    String? positionString;
    switch (position) {
      case CompassViewPosition.TopRight:
        positionString = 'top-right';
        break;
      case CompassViewPosition.TopLeft:
        positionString = 'top-left';
        break;
      case CompassViewPosition.BottomRight:
        positionString = 'bottom-right';
        break;
      case CompassViewPosition.BottomLeft:
        positionString = 'bottom-left';
        break;
      default:
        positionString = null;
    }

    final newShowCompass = compassEnabled ??
        ((_navigationControl?['options'] as JSObject?)?['showCompass']
                as JSBoolean?)
            ?.toDart ??
        false;
    final newPosition = positionString ?? _navigationControlPosition;

    _removeNavigationControl();

    final options = JSObject()
      ..['showCompass'] = newShowCompass.toJS
      ..['showZoom'] = false.toJS
      ..['visualizePitch'] = false.toJS;

    _navigationControl = _newMapboxGlObject('NavigationControl', options);

    if (newPosition == null) {
      _mapOrThrow.callMethodVarArgs('addControl'.toJS, [_navigationControl!]);
    } else {
      _mapOrThrow.callMethodVarArgs(
        'addControl'.toJS,
        [_navigationControl!, newPosition.toJS],
      );
      _navigationControlPosition = newPosition;
    }
  }

  void _setHandlerEnabled(String handlerName, bool enabled) {
    final handler = _mapOrThrow[handlerName] as JSObject?;
    if (handler == null) return;
    handler.callMethodVarArgs(enabled ? 'enable'.toJS : 'disable'.toJS);
  }

  @override
  Future<CameraPosition?> updateMapOptions(
    Map<String, dynamic> optionsUpdate,
  ) async {
    _applyOptionsUpdate(optionsUpdate);
    return _getCameraPosition();
  }

  @override
  Future<bool?> animateCamera(
    CameraUpdate cameraUpdate, {
    Duration? duration,
  }) async {
    _applyCameraUpdate(cameraUpdate, duration: duration);
    return true;
  }

  @override
  Future<bool?> moveCamera(CameraUpdate cameraUpdate) async {
    _applyCameraUpdate(cameraUpdate, duration: Duration.zero);
    return true;
  }

  void _applyCameraUpdate(CameraUpdate cameraUpdate, {Duration? duration}) {
    final json = cameraUpdate.toJson();
    if (json is! List || json.isEmpty) {
      throw ArgumentError.value(json, 'cameraUpdate', 'Invalid CameraUpdate');
    }

    final type = json[0];
    final ms = (duration ?? const Duration(milliseconds: 250)).inMilliseconds;

    JSObject optionsFromPadding(num left, num top, num right, num bottom) {
      return JSObject()
        ..['padding'] = (JSObject()
          ..['left'] = left.toJS
          ..['top'] = top.toJS
          ..['right'] = right.toJS
          ..['bottom'] = bottom.toJS)
        ..['duration'] = ms.toJS;
    }

    switch (type) {
      case 'newCameraPosition':
        final camera = json[1] as Map;
        final target = camera['target'] as List;
        final opts = JSObject()
          ..['center'] = <JSAny?>[
            (target[1] as num).toJS,
            (target[0] as num).toJS,
          ].toJS
          ..['zoom'] = (camera['zoom'] as num?)?.toJS
          ..['bearing'] = (camera['bearing'] as num?)?.toJS
          ..['pitch'] = (camera['tilt'] as num?)?.toJS
          ..['duration'] = ms.toJS;
        _mapOrThrow.callMethodVarArgs('flyTo'.toJS, [opts]);
        return;

      case 'newLatLng':
        final target = json[1] as List;
        final opts = JSObject()
          ..['center'] = <JSAny?>[
            (target[1] as num).toJS,
            (target[0] as num).toJS,
          ].toJS
          ..['duration'] = ms.toJS;
        _mapOrThrow.callMethodVarArgs('flyTo'.toJS, [opts]);
        return;

      case 'newLatLngBounds':
        final bounds = json[1] as List;
        final left = json[2] as num;
        final top = json[3] as num;
        final right = json[4] as num;
        final bottom = json[5] as num;
        final sw = bounds[0] as List;
        final ne = bounds[1] as List;
        final jsBounds = <JSAny?>[
          <JSAny?>[(sw[1] as num).toJS, (sw[0] as num).toJS].toJS,
          <JSAny?>[(ne[1] as num).toJS, (ne[0] as num).toJS].toJS,
        ].toJS;
        _mapOrThrow.callMethodVarArgs(
          'fitBounds'.toJS,
          [jsBounds, optionsFromPadding(left, top, right, bottom)],
        );
        return;

      case 'newLatLngZoom':
        final target = json[1] as List;
        final zoom = json[2] as num;
        final opts = JSObject()
          ..['center'] = <JSAny?>[
            (target[1] as num).toJS,
            (target[0] as num).toJS,
          ].toJS
          ..['zoom'] = zoom.toJS
          ..['duration'] = ms.toJS;
        _mapOrThrow.callMethodVarArgs('flyTo'.toJS, [opts]);
        return;

      case 'scrollBy':
        final dx = json[1] as num;
        final dy = json[2] as num;
        final opts = JSObject()..['duration'] = ms.toJS;
        _mapOrThrow.callMethodVarArgs(
          'panBy'.toJS,
          [
            <JSAny?>[dx.toJS, dy.toJS].toJS,
            opts
          ],
        );
        return;

      case 'zoomBy':
        final amount = json[1] as num;
        final currentZoom = _mapOrThrow
            .callMethodVarArgs<JSNumber>('getZoom'.toJS)
            .toDartDouble;
        final newZoom = (currentZoom + amount).toJS;
        final opts = JSObject()
          ..['zoom'] = newZoom
          ..['duration'] = ms.toJS;
        if (json.length == 3) {
          final focus = json[2] as List;
          final point = JSObject()
            ..['x'] = (focus[0] as num).toJS
            ..['y'] = (focus[1] as num).toJS;
          final around = _mapOrThrow.callMethodVarArgs<JSObject>(
            'unproject'.toJS,
            [point],
          );
          opts['around'] = around;
        }
        _mapOrThrow.callMethodVarArgs('easeTo'.toJS, [opts]);
        return;

      case 'zoomIn':
        _mapOrThrow.callMethodVarArgs('zoomIn'.toJS, [
          JSObject()..['duration'] = ms.toJS,
        ]);
        return;

      case 'zoomOut':
        _mapOrThrow.callMethodVarArgs('zoomOut'.toJS, [
          JSObject()..['duration'] = ms.toJS,
        ]);
        return;

      case 'zoomTo':
        final zoom = json[1] as num;
        _mapOrThrow.callMethodVarArgs('easeTo'.toJS, [
          JSObject()
            ..['zoom'] = zoom.toJS
            ..['duration'] = ms.toJS
        ]);
        return;

      case 'bearingTo':
        final bearing = json[1] as num;
        _mapOrThrow.callMethodVarArgs('easeTo'.toJS, [
          JSObject()
            ..['bearing'] = bearing.toJS
            ..['duration'] = ms.toJS
        ]);
        return;

      case 'tiltTo':
        final pitch = json[1] as num;
        _mapOrThrow.callMethodVarArgs('easeTo'.toJS, [
          JSObject()
            ..['pitch'] = pitch.toJS
            ..['duration'] = ms.toJS
        ]);
        return;

      default:
        throw UnimplementedError('Unsupported CameraUpdate: $type');
    }
  }

  @override
  Future<void> updateMyLocationTrackingMode(
    MyLocationTrackingMode myLocationTrackingMode,
  ) async {
    setMyLocationTrackingMode(myLocationTrackingMode.index);
  }

  @override
  Future<void> matchMapLanguageWithDeviceDefault() async {
    setMapLanguage(ui.PlatformDispatcher.instance.locale.languageCode);
  }

  @override
  Future<void> setMapLanguage(String language) async {
    _mapOrThrow.callMethodVarArgs(
      'setLayoutProperty'.toJS,
      [
        'country-label'.toJS,
        'text-field'.toJS,
        _jsify(['get', 'name_$language']),
      ],
    );
  }

  @override
  Future<void> setTelemetryEnabled(bool enabled) async {
    debugPrint('Telemetry not available in web');
  }

  @override
  Future<bool> getTelemetryEnabled() async {
    debugPrint('Telemetry not available in web');
    return false;
  }

  @override
  Future<List> queryRenderedFeatures(
    Point<double> point,
    List<String> layerIds,
    List<Object>? filter,
  ) async {
    final options = JSObject();
    if (layerIds.isNotEmpty) {
      options['layers'] = layerIds.map((l) => l.toJS).toList().toJS;
    }
    if (filter != null) {
      options['filter'] = _jsify(filter);
    }

    final p = <JSAny?>[point.x.toJS, point.y.toJS].toJS;
    final bbox = <JSAny?>[p, p].toJS;
    final features = _mapOrThrow.callMethodVarArgs<JSArray<JSAny?>>(
      'queryRenderedFeatures'.toJS,
      [bbox, options],
    );

    final out = <dynamic>[];
    for (var i = 0; i < features.length; i++) {
      final fAny = features[i];
      final f = _dartifyViaJson(fAny) as Map<String, dynamic>;
      out.add({
        'type': 'Feature',
        'id': f['id'],
        'geometry': f['geometry'],
        'properties': f['properties'],
        'source': f['source'],
      });
    }
    return out;
  }

  @override
  Future<List> queryRenderedFeaturesInRect(
    Rect rect,
    List<String> layerIds,
    String? filter,
  ) async {
    final options = JSObject();
    if (layerIds.isNotEmpty) {
      options['layers'] = layerIds.map((l) => l.toJS).toList().toJS;
    }
    if (filter != null && filter.isNotEmpty) {
      try {
        options['filter'] = _jsify(jsonDecode(filter));
      } catch (_) {
        // ignore
      }
    }

    final bbox = <JSAny?>[
      <JSAny?>[rect.left.toJS, rect.bottom.toJS].toJS,
      <JSAny?>[rect.right.toJS, rect.top.toJS].toJS,
    ].toJS;

    final features = _mapOrThrow.callMethodVarArgs<JSArray<JSAny?>>(
      'queryRenderedFeatures'.toJS,
      [bbox, options],
    );

    final out = <dynamic>[];
    for (var i = 0; i < features.length; i++) {
      final fAny = features[i];
      final f = _dartifyViaJson(fAny) as Map<String, dynamic>;
      out.add({
        'type': 'Feature',
        'id': f['id'],
        'geometry': f['geometry'],
        'properties': f['properties'],
        'source': f['source'],
      });
    }
    return out;
  }

  @override
  Future invalidateAmbientCache() async {
    debugPrint('Offline storage not available in web');
  }

  @override
  Future<LatLng?> requestMyLocationLatLng() async => _myLastLocation;

  @override
  Future<LatLngBounds> getVisibleRegion() async {
    final bounds = _mapOrThrow.callMethodVarArgs<JSObject>('getBounds'.toJS);
    final sw = bounds.callMethodVarArgs<JSObject>('getSouthWest'.toJS);
    final ne = bounds.callMethodVarArgs<JSObject>('getNorthEast'.toJS);
    return LatLngBounds(
      southwest: LatLng(
        (sw['lat'] as JSNumber).toDartDouble,
        (sw['lng'] as JSNumber).toDartDouble,
      ),
      northeast: LatLng(
        (ne['lat'] as JSNumber).toDartDouble,
        (ne['lng'] as JSNumber).toDartDouble,
      ),
    );
  }

  @override
  Future<void> addImage(String name, Uint8List bytes,
      [bool sdf = false]) async {
    final decoded = decodeImage(bytes);
    if (decoded == null) return;

    final hasImage = _mapOrThrow
        .callMethodVarArgs<JSBoolean>('hasImage'.toJS, [name.toJS]).toDart;
    if (hasImage) return;

    final image = JSObject()
      ..['width'] = decoded.width.toJS
      ..['height'] = decoded.height.toJS
      ..['data'] = decoded.getBytes().toJS;

    _mapOrThrow.callMethodVarArgs(
      'addImage'.toJS,
      [
        name.toJS,
        image,
        JSObject()..['sdf'] = sdf.toJS,
      ],
    );
  }

  @override
  Future<void> addGeoJsonSource(
    String sourceId,
    Map<String, dynamic> geojson, {
    String? promoteId,
  }) async {
    _geoJsonBySourceId[sourceId] = geojson;
    final source = JSObject()
      ..['type'] = 'geojson'.toJS
      ..['data'] = _jsify(geojson);
    if (promoteId != null) {
      source['promoteId'] = promoteId.toJS;
    }
    _mapOrThrow.callMethodVarArgs('addSource'.toJS, [sourceId.toJS, source]);
  }

  @override
  Future<void> setGeoJsonSource(
    String sourceId,
    Map<String, dynamic> geojson,
  ) async {
    _geoJsonBySourceId[sourceId] = geojson;
    final source = _mapOrThrow
        .callMethodVarArgs<JSObject>('getSource'.toJS, [sourceId.toJS]);
    source.callMethodVarArgs('setData'.toJS, [_jsify(geojson)]);
  }

  @override
  Future<void> setFeatureForGeoJsonSource(
    String sourceId,
    Map<String, dynamic> geojsonFeature,
  ) async {
    final data = _geoJsonBySourceId[sourceId];
    if (data == null) return;

    final features = (data['features'] as List?)?.toList() ?? <dynamic>[];

    dynamic featureId =
        geojsonFeature['properties']?['id'] ?? geojsonFeature['id'];
    if (featureId == null) return;

    final index = features.indexWhere((f) {
      if (f is! Map) return false;
      return f['properties']?['id'] == featureId || f['id'] == featureId;
    });
    if (index < 0) return;

    features[index] = geojsonFeature;
    final updated = <String, dynamic>{
      ...data,
      'features': features,
    };
    _geoJsonBySourceId[sourceId] = updated;

    final source = _mapOrThrow
        .callMethodVarArgs<JSObject>('getSource'.toJS, [sourceId.toJS]);
    source.callMethodVarArgs('setData'.toJS, [_jsify(updated)]);
  }

  @override
  Future<void> removeSource(String sourceId) async {
    final source = _mapOrThrow
        .callMethodVarArgs<JSAny?>('getSource'.toJS, [sourceId.toJS]);
    if (source == null) return;
    _geoJsonBySourceId.remove(sourceId);
    _mapOrThrow.callMethodVarArgs('removeSource'.toJS, [sourceId.toJS]);
  }

  @override
  Future<void> addSymbolLayer(
    String sourceId,
    String layerId,
    Map<String, dynamic> properties, {
    String? belowLayerId,
    String? sourceLayer,
    double? minzoom,
    double? maxzoom,
    dynamic filter,
    required bool enableInteraction,
  }) async {
    await _addStyleLayer(
      sourceId,
      layerId,
      properties,
      'symbol',
      belowLayerId: belowLayerId,
      sourceLayer: sourceLayer,
      minzoom: minzoom,
      maxzoom: maxzoom,
      filter: filter,
      enableInteraction: enableInteraction,
    );
  }

  @override
  Future<void> addLineLayer(
    String sourceId,
    String layerId,
    Map<String, dynamic> properties, {
    String? belowLayerId,
    String? sourceLayer,
    double? minzoom,
    double? maxzoom,
    dynamic filter,
    required bool enableInteraction,
  }) async {
    await _addStyleLayer(
      sourceId,
      layerId,
      properties,
      'line',
      belowLayerId: belowLayerId,
      sourceLayer: sourceLayer,
      minzoom: minzoom,
      maxzoom: maxzoom,
      filter: filter,
      enableInteraction: enableInteraction,
    );
  }

  @override
  Future<void> addCircleLayer(
    String sourceId,
    String layerId,
    Map<String, dynamic> properties, {
    String? belowLayerId,
    String? sourceLayer,
    double? minzoom,
    double? maxzoom,
    dynamic filter,
    required bool enableInteraction,
  }) async {
    await _addStyleLayer(
      sourceId,
      layerId,
      properties,
      'circle',
      belowLayerId: belowLayerId,
      sourceLayer: sourceLayer,
      minzoom: minzoom,
      maxzoom: maxzoom,
      filter: filter,
      enableInteraction: enableInteraction,
    );
  }

  @override
  Future<void> addFillLayer(
    String sourceId,
    String layerId,
    Map<String, dynamic> properties, {
    String? belowLayerId,
    String? sourceLayer,
    double? minzoom,
    double? maxzoom,
    dynamic filter,
    required bool enableInteraction,
  }) async {
    await _addStyleLayer(
      sourceId,
      layerId,
      properties,
      'fill',
      belowLayerId: belowLayerId,
      sourceLayer: sourceLayer,
      minzoom: minzoom,
      maxzoom: maxzoom,
      filter: filter,
      enableInteraction: enableInteraction,
    );
  }

  @override
  Future<void> addFillExtrusionLayer(
    String sourceId,
    String layerId,
    Map<String, dynamic> properties, {
    String? belowLayerId,
    String? sourceLayer,
    double? minzoom,
    double? maxzoom,
    dynamic filter,
    required bool enableInteraction,
  }) async {
    await _addStyleLayer(
      sourceId,
      layerId,
      properties,
      'fill-extrusion',
      belowLayerId: belowLayerId,
      sourceLayer: sourceLayer,
      minzoom: minzoom,
      maxzoom: maxzoom,
      filter: filter,
      enableInteraction: enableInteraction,
    );
  }

  @override
  Future<void> addRasterLayer(
    String sourceId,
    String layerId,
    Map<String, dynamic> properties, {
    String? belowLayerId,
    String? sourceLayer,
    double? minzoom,
    double? maxzoom,
  }) async {
    await _addStyleLayer(
      sourceId,
      layerId,
      properties,
      'raster',
      belowLayerId: belowLayerId,
      sourceLayer: sourceLayer,
      minzoom: minzoom,
      maxzoom: maxzoom,
      enableInteraction: false,
    );
  }

  @override
  Future<void> addHillshadeLayer(
    String sourceId,
    String layerId,
    Map<String, dynamic> properties, {
    String? belowLayerId,
    String? sourceLayer,
    double? minzoom,
    double? maxzoom,
  }) async {
    await _addStyleLayer(
      sourceId,
      layerId,
      properties,
      'hillshade',
      belowLayerId: belowLayerId,
      sourceLayer: sourceLayer,
      minzoom: minzoom,
      maxzoom: maxzoom,
      enableInteraction: false,
    );
  }

  @override
  Future<void> addHeatmapLayer(
    String sourceId,
    String layerId,
    Map<String, dynamic> properties, {
    String? belowLayerId,
    String? sourceLayer,
    double? minzoom,
    double? maxzoom,
  }) async {
    await _addStyleLayer(
      sourceId,
      layerId,
      properties,
      'heatmap',
      belowLayerId: belowLayerId,
      sourceLayer: sourceLayer,
      minzoom: minzoom,
      maxzoom: maxzoom,
      enableInteraction: false,
    );
  }

  Future<void> _addStyleLayer(
    String sourceId,
    String layerId,
    Map<String, dynamic> properties,
    String layerType, {
    String? belowLayerId,
    String? sourceLayer,
    double? minzoom,
    double? maxzoom,
    dynamic filter,
    required bool enableInteraction,
  }) async {
    final layout = Map.fromEntries(
      properties.entries.where((entry) => isLayoutProperty(entry.key)),
    );
    final paint = Map.fromEntries(
      properties.entries.where((entry) => !isLayoutProperty(entry.key)),
    );

    await removeLayer(layerId);

    final layer = JSObject()
      ..['id'] = layerId.toJS
      ..['type'] = layerType.toJS
      ..['source'] = sourceId.toJS
      ..['layout'] = _jsify(layout)
      ..['paint'] = _jsify(paint);

    if (sourceLayer != null) layer['source-layer'] = sourceLayer.toJS;
    if (minzoom != null) layer['minzoom'] = minzoom.toJS;
    if (maxzoom != null) layer['maxzoom'] = maxzoom.toJS;
    if (filter != null) layer['filter'] = _jsify(filter);

    _mapOrThrow.callMethodVarArgs(
      'addLayer'.toJS,
      [layer, if (belowLayerId != null) belowLayerId.toJS],
    );

    if (enableInteraction) {
      _interactiveFeatureLayerIds.add(layerId);
      if (layerType == 'fill') {
        _mapOnLayer('mousemove', layerId, _onMouseEnterFeatureJs);
      } else {
        _mapOnLayer('mouseenter', layerId, _onMouseEnterFeatureJs);
      }
      _mapOnLayer('mouseleave', layerId, _onMouseLeaveFeatureJs);
      if (_dragEnabled) _mapOnLayer('mousedown', layerId, _onMouseDownJs);
    }
  }

  @override
  Future<void> removeLayer(String layerId) async {
    final layer =
        _mapOrThrow.callMethodVarArgs<JSAny?>('getLayer'.toJS, [layerId.toJS]);
    if (layer == null) return;

    _interactiveFeatureLayerIds.remove(layerId);
    _mapOffLayer('mouseenter', layerId, _onMouseEnterFeatureJs);
    _mapOffLayer('mousemove', layerId, _onMouseEnterFeatureJs);
    _mapOffLayer('mouseleave', layerId, _onMouseLeaveFeatureJs);
    if (_dragEnabled) _mapOffLayer('mousedown', layerId, _onMouseDownJs);

    _mapOrThrow.callMethodVarArgs('removeLayer'.toJS, [layerId.toJS]);
  }

  @override
  Future<void> setFilter(String layerId, dynamic filter) async {
    _mapOrThrow.callMethodVarArgs(
      'setFilter'.toJS,
      [layerId.toJS, _jsify(filter)],
    );
  }

  @override
  Future<void> setVisibility(String layerId, bool isVisible) async {
    final layer =
        _mapOrThrow.callMethodVarArgs<JSAny?>('getLayer'.toJS, [layerId.toJS]);
    if (layer == null) return;
    _mapOrThrow.callMethodVarArgs(
      'setLayoutProperty'.toJS,
      [layerId.toJS, 'visibility'.toJS, (isVisible ? 'visible' : 'none').toJS],
    );
  }

  @override
  Future<Point> toScreenLocation(LatLng latLng) async {
    final point = _mapOrThrow.callMethodVarArgs<JSObject>(
      'project'.toJS,
      [
        <JSAny?>[latLng.longitude.toJS, latLng.latitude.toJS].toJS,
      ],
    );
    return Point(
      (point['x'] as JSNumber).toDartDouble.round(),
      (point['y'] as JSNumber).toDartDouble.round(),
    );
  }

  @override
  Future<List<Point>> toScreenLocationBatch(Iterable<LatLng> latLngs) async {
    return [
      for (final latLng in latLngs) await toScreenLocation(latLng),
    ];
  }

  @override
  Future<LatLng> toLatLng(Point screenLocation) async {
    final point = JSObject()
      ..['x'] = screenLocation.x.toJS
      ..['y'] = screenLocation.y.toJS;
    final lngLat = _mapOrThrow.callMethodVarArgs<JSObject>(
      'unproject'.toJS,
      [point],
    );
    return LatLng(
      (lngLat['lat'] as JSNumber).toDartDouble,
      (lngLat['lng'] as JSNumber).toDartDouble,
    );
  }

  @override
  Future<double> getMetersPerPixelAtLatitude(double latitude) async {
    // https://wiki.openstreetmap.org/wiki/Zoom_levels
    const circumference = 40075017.686;
    final zoom =
        _mapOrThrow.callMethodVarArgs<JSNumber>('getZoom'.toJS).toDartDouble;
    return circumference * cos(latitude * (pi / 180)) / pow(2, zoom + 9);
  }

  @override
  Future<void> addSource(String sourceId, SourceProperties properties) async {
    _mapOrThrow.callMethodVarArgs(
      'addSource'.toJS,
      [sourceId.toJS, _jsify(properties.toJson())],
    );
  }

  @override
  Future<void> addImageSource(
    String imageSourceId,
    Uint8List bytes,
    LatLngQuad coordinates,
  ) async {
    // Mapbox GL JS image sources require a URL; use a data URL by default.
    final dataUrl = 'data:image/png;base64,${base64Encode(bytes)}';
    _imageSourceDataUrlById[imageSourceId] = dataUrl;

    final coords = <JSAny?>[
      <JSAny?>[
        coordinates.topLeft.longitude.toJS,
        coordinates.topLeft.latitude.toJS,
      ].toJS,
      <JSAny?>[
        coordinates.topRight.longitude.toJS,
        coordinates.topRight.latitude.toJS,
      ].toJS,
      <JSAny?>[
        coordinates.bottomRight.longitude.toJS,
        coordinates.bottomRight.latitude.toJS,
      ].toJS,
      <JSAny?>[
        coordinates.bottomLeft.longitude.toJS,
        coordinates.bottomLeft.latitude.toJS,
      ].toJS,
    ].toJS;

    final source = JSObject()
      ..['type'] = 'image'.toJS
      ..['url'] = dataUrl.toJS
      ..['coordinates'] = coords;

    _mapOrThrow
        .callMethodVarArgs('addSource'.toJS, [imageSourceId.toJS, source]);
  }

  @override
  Future<void> updateImageSource(
    String imageSourceId,
    Uint8List? bytes,
    LatLngQuad? coordinates,
  ) async {
    final source = _mapOrThrow
        .callMethodVarArgs<JSObject>('getSource'.toJS, [imageSourceId.toJS]);

    String? url;
    if (bytes != null) {
      url = 'data:image/png;base64,${base64Encode(bytes)}';
      _imageSourceDataUrlById[imageSourceId] = url;
    } else {
      url = _imageSourceDataUrlById[imageSourceId];
    }

    JSAny? coords;
    if (coordinates != null) {
      coords = <JSAny?>[
        <JSAny?>[
          coordinates.topLeft.longitude.toJS,
          coordinates.topLeft.latitude.toJS,
        ].toJS,
        <JSAny?>[
          coordinates.topRight.longitude.toJS,
          coordinates.topRight.latitude.toJS,
        ].toJS,
        <JSAny?>[
          coordinates.bottomRight.longitude.toJS,
          coordinates.bottomRight.latitude.toJS,
        ].toJS,
        <JSAny?>[
          coordinates.bottomLeft.longitude.toJS,
          coordinates.bottomLeft.latitude.toJS,
        ].toJS,
      ].toJS;
    }

    final opts = JSObject();
    if (url != null) opts['url'] = url.toJS;
    if (coords != null) opts['coordinates'] = coords;

    source.callMethodVarArgs('updateImage'.toJS, [opts]);
  }

  @override
  Future<void> addLayer(
    String imageLayerId,
    String imageSourceId,
    double? minzoom,
    double? maxzoom,
  ) async {
    final layer = JSObject()
      ..['id'] = imageLayerId.toJS
      ..['type'] = 'raster'.toJS
      ..['source'] = imageSourceId.toJS;
    if (minzoom != null) layer['minzoom'] = minzoom.toJS;
    if (maxzoom != null) layer['maxzoom'] = maxzoom.toJS;
    await removeLayer(imageLayerId);
    _mapOrThrow.callMethodVarArgs('addLayer'.toJS, [layer]);
  }

  @override
  Future<void> addLayerBelow(
    String imageLayerId,
    String imageSourceId,
    String belowLayerId,
    double? minzoom,
    double? maxzoom,
  ) async {
    final layer = JSObject()
      ..['id'] = imageLayerId.toJS
      ..['type'] = 'raster'.toJS
      ..['source'] = imageSourceId.toJS;
    if (minzoom != null) layer['minzoom'] = minzoom.toJS;
    if (maxzoom != null) layer['maxzoom'] = maxzoom.toJS;
    await removeLayer(imageLayerId);
    _mapOrThrow.callMethodVarArgs('addLayer'.toJS, [layer, belowLayerId.toJS]);
  }

  @override
  Future<void> updateContentInsets(EdgeInsets insets, bool animated) async {
    final padding = JSObject()
      ..['left'] = insets.left.toJS
      ..['top'] = insets.top.toJS
      ..['right'] = insets.right.toJS
      ..['bottom'] = insets.bottom.toJS;

    final opts = JSObject()
      ..['padding'] = padding
      ..['duration'] = (animated ? 250 : 0).toJS;
    _mapOrThrow.callMethodVarArgs('easeTo'.toJS, [opts]);
  }

  @override
  Future<String> takeSnapshot(SnapshotOptions snapshotOptions) async {
    if (snapshotOptions.styleUri != null || snapshotOptions.styleJson != null) {
      throw UnsupportedError('style option is not supported on web');
    }
    if (snapshotOptions.bounds != null) {
      throw UnsupportedError('bounds option is not supported on web');
    }
    if (snapshotOptions.centerCoordinate != null ||
        snapshotOptions.zoomLevel != null ||
        snapshotOptions.pitch != 0 ||
        snapshotOptions.heading != 0) {
      throw UnsupportedError('camera option is not supported on web');
    }

    final canvas =
        _mapOrThrow.callMethodVarArgs<web.HTMLCanvasElement>('getCanvas'.toJS);
    return canvas.toDataURL('image/png');
  }

  @override
  void resizeWebMap() {
    _onMapResize();
  }

  @override
  void forceResizeWebMap() {
    _mapOrThrow.callMethodVarArgs('resize'.toJS);
  }

  /*
   *  MapboxMapOptionsSink
   */
  @override
  void setAttributionButtonMargins(int x, int y) {
    debugPrint('setAttributionButtonMargins not available in web');
  }

  @override
  void setCameraTargetBounds(LatLngBounds? bounds) {
    if (bounds == null) {
      _mapOrThrow.callMethodVarArgs('setMaxBounds'.toJS, [null]);
      return;
    }
    final sw = <JSAny?>[
      bounds.southwest.longitude.toJS,
      bounds.southwest.latitude.toJS,
    ].toJS;
    final ne = <JSAny?>[
      bounds.northeast.longitude.toJS,
      bounds.northeast.latitude.toJS,
    ].toJS;
    _mapOrThrow.callMethodVarArgs('setMaxBounds'.toJS, [
      <JSAny?>[sw, ne].toJS
    ]);
  }

  @override
  void setCompassEnabled(bool compassEnabled) {
    _updateNavigationControl(compassEnabled: compassEnabled);
  }

  @override
  void setCompassAlignment(CompassViewPosition position) {
    _updateNavigationControl(position: position);
  }

  @override
  void setAttributionButtonAlignment(AttributionButtonPosition position) {
    debugPrint('setAttributionButtonAlignment not available in web');
  }

  @override
  void setCompassViewMargins(int x, int y) {
    debugPrint('setCompassViewMargins not available in web');
  }

  @override
  void setLogoViewMargins(int x, int y) {
    debugPrint('setLogoViewMargins not available in web');
  }

  @override
  void setMinMaxZoomPreference(num? min, num? max) {
    final minZoom = (min ?? 0).toJS;
    final maxZoom = (max ?? _defaultMaxZoom).toJS;
    _mapOrThrow.callMethodVarArgs('setMinZoom'.toJS, [minZoom]);
    _mapOrThrow.callMethodVarArgs('setMaxZoom'.toJS, [maxZoom]);
  }

  @override
  void setMyLocationEnabled(bool myLocationEnabled) {
    if (myLocationEnabled) {
      _addGeolocateControl(trackUserLocation: false);
    } else {
      _removeGeolocateControl();
    }
  }

  @override
  void setMyLocationRenderMode(int myLocationRenderMode) {
    debugPrint('myLocationRenderMode not available in web');
  }

  @override
  void setMyLocationTrackingMode(int myLocationTrackingMode) {
    if (_geolocateControl == null) {
      return;
    }
    if (myLocationTrackingMode == 0) {
      _addGeolocateControl(trackUserLocation: false);
    } else {
      _addGeolocateControl(trackUserLocation: true);
    }
  }

  @override
  void setStyleString(String? styleString) {
    for (final layerId in _interactiveFeatureLayerIds) {
      _mapOffLayer('mouseenter', layerId, _onMouseEnterFeatureJs);
      _mapOffLayer('mousemove', layerId, _onMouseEnterFeatureJs);
      _mapOffLayer('mouseleave', layerId, _onMouseLeaveFeatureJs);
      if (_dragEnabled) _mapOffLayer('mousedown', layerId, _onMouseDownJs);
    }
    _interactiveFeatureLayerIds.clear();

    final shouldWaitForStyleLoad = _mapReady;
    if (shouldWaitForStyleLoad) {
      _mapReady = false;
      _mapOnce('styledata', _onStyleLoadedJs);
    }

    try {
      final styleJson = jsonDecode(styleString ?? '');
      _mapOrThrow.callMethodVarArgs('setStyle'.toJS, [_jsify(styleJson)]);
    } catch (_) {
      _mapOrThrow.callMethodVarArgs('setStyle'.toJS, [styleString?.toJS]);
    }
  }

  @override
  void setGestures({
    required bool rotateGesturesEnabled,
    required bool scrollGesturesEnabled,
    required bool tiltGesturesEnabled,
    required bool zoomGesturesEnabled,
    required bool doubleClickZoomEnabled,
  }) {
    _setHandlerEnabled('dragPan', scrollGesturesEnabled);
    _setHandlerEnabled('scrollZoom', zoomGesturesEnabled);
    _setHandlerEnabled('doubleClickZoom', doubleClickZoomEnabled);

    // dragRotate is shared by both gestures.
    _setHandlerEnabled(
        'dragRotate', tiltGesturesEnabled && rotateGesturesEnabled);

    // touchZoomRotate handles pinch zoom and rotation.
    _setHandlerEnabled(
        'touchZoomRotate', zoomGesturesEnabled || rotateGesturesEnabled);
  }

  @override
  void setTrackCameraPosition(bool trackCameraPosition) {
    _trackCameraPosition = trackCameraPosition;
  }
}
