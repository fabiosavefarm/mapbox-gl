{{flutter_js}}
{{flutter_build_config}}

(function () {
  const params = new URLSearchParams(window.location.search);
  const forceSingleThreadedSkwasm = params.get('single_threaded') !== '0';

  console.info('[mapbox_gl_example] bootstrap', {
    renderer: 'skwasm',
    forceSingleThreadedSkwasm,
  });

  _flutter.loader.load({
    config: {
      renderer: 'skwasm',
      forceSingleThreadedSkwasm,
    },
  });
})();
