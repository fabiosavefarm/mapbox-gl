import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mapbox_gl/mapbox_gl.dart';

const String _accessToken = String.fromEnvironment('ACCESS_TOKEN');
const LatLng _initialTarget = LatLng(-14.2350, -51.9253);

void main() {
  final errors = ValueNotifier<String?>(null);

  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    errors.value = details.exceptionAsString();
  };

  PlatformDispatcher.instance.onError = (Object error, StackTrace stackTrace) {
    errors.value = error.toString();
    print('[mapbox_gl_example] uncaught error=$error');
    print(stackTrace);
    return true;
  };

  runApp(WasmSmokeApp(errors: errors));
}

class WasmSmokeApp extends StatelessWidget {
  const WasmSmokeApp({super.key, required this.errors});

  final ValueNotifier<String?> errors;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Mapbox WASM Smoke',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.blue),
      home: WasmSmokePage(errors: errors),
    );
  }
}

class WasmSmokePage extends StatefulWidget {
  const WasmSmokePage({super.key, required this.errors});

  final ValueNotifier<String?> errors;

  @override
  State<WasmSmokePage> createState() => _WasmSmokePageState();
}

class _WasmSmokePageState extends State<WasmSmokePage> {
  MapboxMapController? _controller;
  String _status = 'booting';
  String? _projectionInfo;
  String? _unprojectionInfo;

  String get _renderer {
    if (isSkwasm) return 'skwasm';
    if (isCanvasKit) return 'canvaskit';
    if (kIsWasm) return 'wasm-unknown';
    return 'js';
  }

  void _setStatus(String value) {
    if (!mounted) return;
    setState(() {
      _status = value;
    });
  }

  void _onMapCreated(MapboxMapController controller) {
    print('[mapbox_gl_example] map created renderer=$_renderer wasm=$kIsWasm');
    _controller = controller;
    _setStatus('map-created');
  }

  Future<void> _onStyleLoaded() async {
    print('[mapbox_gl_example] style loaded renderer=$_renderer');
    _setStatus('style-loaded');
    await _probeProjection();
  }

  Future<void> _probeProjection() async {
    final controller = _controller;
    if (controller == null) {
      _setStatus('projection-skipped:no-controller');
      return;
    }

    try {
      final projected = await controller.toScreenLocation(_initialTarget);
      final restored = await controller.toLatLng(projected);
      if (!mounted) return;
      setState(() {
        _projectionInfo = 'screen=(${projected.x}, ${projected.y})';
        _unprojectionInfo =
            'lat=${restored.latitude.toStringAsFixed(6)} lon=${restored.longitude.toStringAsFixed(6)}';
        _status = 'projection-ok';
      });
      print(
        '[mapbox_gl_example] projection ok renderer=$_renderer point=$projected restored=$restored',
      );
    } catch (error, stackTrace) {
      widget.errors.value = error.toString();
      _setStatus('projection-error');
      print('[mapbox_gl_example] projection error=$error');
      print(stackTrace);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_accessToken.isEmpty || _accessToken.contains('YOUR_TOKEN')) {
      return Scaffold(
        appBar: AppBar(title: const Text('Mapbox WASM Smoke')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Passe o token com --dart-define=ACCESS_TOKEN=SEU_TOKEN',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Mapbox WASM Smoke'),
        actions: [
          IconButton(
            tooltip: 'Projeção',
            onPressed: () => unawaited(_probeProjection()),
            icon: const Icon(Icons.center_focus_strong),
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MapboxMap(
            accessToken: _accessToken,
            initialCameraPosition: const CameraPosition(
              target: _initialTarget,
              zoom: 4.2,
              tilt: 40,
              bearing: -18,
            ),
            styleString: MapboxStyles.SATELLITE_STREETS,
            trackCameraPosition: true,
            onMapCreated: _onMapCreated,
            onStyleLoadedCallback: () => unawaited(_onStyleLoaded()),
          ),
          Positioned(
            left: 16,
            top: 16,
            child: Material(
              elevation: 4,
              borderRadius: BorderRadius.circular(12),
              child: Container(
                width: 360,
                padding: const EdgeInsets.all(16),
                child: ValueListenableBuilder<String?>(
                  valueListenable: widget.errors,
                  builder: (context, error, _) {
                    return DefaultTextStyle(
                      style: Theme.of(context).textTheme.bodyMedium!,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Runtime',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          Text('renderer=$_renderer'),
                          Text('wasm=$kIsWasm web=$kIsWeb'),
                          Text('status=$_status'),
                          const SizedBox(height: 12),
                          Text(
                            'Projection',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          Text(_projectionInfo ?? 'screen=not-run'),
                          Text(_unprojectionInfo ?? 'latlng=not-run'),
                          const SizedBox(height: 12),
                          Text(
                            'Error',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          Text(error ?? 'none'),
                          const SizedBox(height: 12),
                          const Text(
                            'Use ?mapbox_gl_web_debug=1 no browser para logs detalhados do plugin.',
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
