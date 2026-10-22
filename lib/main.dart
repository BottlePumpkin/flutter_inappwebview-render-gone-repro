import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// Minimal repro: an InAppWebView that handles onRenderProcessGone by recreating itself
/// (new widget key), which disposes the old platform WebView.
///
/// Scenarios (adb shell am start ... --es scenario X --ei delay N):
///  K: kill once  -> recreate. Watch whether the old WebView ever reaches destroy().
///  A: kill once  -> recreate -> kill again after `delay` ms (inside the dispose window).
///  B: recreate (no kill) with the instrumented plugin terminating the renderer inside dispose().
///  E: (use --es method crash) crash the renderer, then recreate `delay` ms later, i.e. dispose
///     while the crash is still being reported (crash detection takes seconds).
///  G: (use --es method crash) push a second WebView page; once it has loaded, crash the renderer
///     through the home WebView, then pop the second page `delay` ms later, i.e. its dispose()
///     runs while the crash is still being reported.
///  C: push a second WebView page -> pop it -> kill `delay` ms after the page's State.dispose()
///     (the plugin's platform-view dispose is sent just before that).
const _channel = MethodChannel('repro');

Completer<void>? _secondDisposed;
Completer<void>? _secondLoaded;

Future<void> log(String msg) async {
  debugPrint('REPRO-dart $msg');
  await _channel.invokeMethod('log', {'msg': msg});
}

Future<bool> terminate(String reason, {bool forceKill = false, String target = 'last'}) async {
  final r = await _channel.invokeMapMethod<String, dynamic>(
    'terminate',
    {'reason': reason, 'forceKill': forceKill, 'target': target},
  );
  await log('terminate($reason) -> $r');
  return r?['ok'] == true;
}

/// Retries until a live renderer is found and terminated (e.g. a freshly respawned one).
Future<bool> terminateWhenAlive(
  String reason, {
  Duration every = const Duration(milliseconds: 5),
  int tries = 400,
  bool forceKill = false,
  String target = 'last',
}) async {
  for (var i = 0; i < tries; i++) {
    if (await terminate('$reason#$i', forceKill: forceKill, target: target)) return true;
    await Future.delayed(every);
  }
  return false;
}

void main() => runApp(const MaterialApp(home: HomePage()));

InAppWebViewSettings get _settings => InAppWebViewSettings(useOnRenderProcessGone: true);

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _gen = 0;
  String _scenario = '';
  int _delay = 0;
  String _method = 'kill';
  int _thenKillAfter = -1;
  bool _started = false;
  bool _configLoaded = false;
  bool _firstLoaded = false;

  @override
  void initState() {
    super.initState();
    _channel.invokeMapMethod<String, dynamic>('getConfig').then((c) {
      setState(() {
        _scenario = c?['scenario'] as String? ?? '';
        _delay = c?['delay'] as int? ?? 0;
        _method = c?['method'] as String? ?? 'kill';
        _thenKillAfter = c?['thenKillAfter'] as int? ?? -1;
        _configLoaded = true;
      });
      log('config scenario=$_scenario delay=$_delay method=$_method');
      _autorun();
    });
  }

  void _recreate(String why) {
    setState(() => _gen++);
    log('recreate($why) -> gen=$_gen');
  }

  Future<void> _autorun() async {
    if (_started || !_configLoaded || !_firstLoaded || _scenario.isEmpty) return;
    _started = true;
    await log('scenario $_scenario start');
    switch (_scenario) {
      case 'K':
      case 'A':
        await terminateWhenAlive('$_scenario-1', every: const Duration(milliseconds: 100), tries: 30);
      case 'E':
        await terminateWhenAlive('E-1', every: const Duration(milliseconds: 100), tries: 30);
        await Future.delayed(Duration(milliseconds: _delay));
        _recreate('E');
      case 'G':
        if (!mounted) return;
        _secondDisposed = Completer<void>();
        _secondLoaded = Completer<void>();
        final nav = Navigator.of(context);
        unawaited(nav.push(MaterialPageRoute(builder: (_) => const SecondPage())));
        await _secondLoaded!.future;
        await terminateWhenAlive('G-1', every: const Duration(milliseconds: 100), tries: 30, target: 'first');
        await Future.delayed(Duration(milliseconds: _delay));
        await log('G: popping second page');
        nav.pop();
        await _secondDisposed!.future;
        await log('G: second page disposed');
      case 'B':
        await Future.delayed(const Duration(milliseconds: 500));
        _recreate('B');
      case 'C':
        if (!mounted) return;
        _secondDisposed = Completer<void>();
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SecondPage()));
        await log('C: popped');
        await _secondDisposed!.future;
        await log('C: second page disposed, killing in ${_delay}ms');
        await Future.delayed(Duration(milliseconds: _delay));
        await terminateWhenAlive('C');
    }
    // The app is still alive if this line shows up.
    // Optional follow-up (--ei thenKillAfter N): one plain kill N ms later, to probe WebViews that
    // started dispose() but never reached destroy().
    if (_thenKillAfter >= 0) {
      await Future.delayed(Duration(milliseconds: _thenKillAfter));
      await log('then-kill after ${_thenKillAfter}ms');
      await terminateWhenAlive('then', every: const Duration(milliseconds: 100), tries: 30, forceKill: true);
    }
    // A crash (unlike a kill) takes several seconds to be reported, so wait longer for it.
    await Future.delayed(Duration(seconds: _method == 'crash' ? 15 : 5));
    await log('ALIVE scenario=$_scenario method=$_method delay=$_delay gen=$_gen');
  }

  Future<void> _onRenderProcessGone(RenderProcessGoneDetail d) async {
    await log('onRenderProcessGone gen=$_gen didCrash=${d.didCrash}');
    _recreate('renderProcessGone');
    if (_scenario == 'A' && _gen == 1) {
      await Future.delayed(Duration(milliseconds: _delay));
      await terminateWhenAlive('A-2');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('repro gen=$_gen scenario=$_scenario')),
      body: Column(
        children: [
          Wrap(
            spacing: 8,
            children: [
              ElevatedButton(onPressed: () => terminate('manual'), child: const Text('Kill renderer')),
              ElevatedButton(onPressed: () => _recreate('manual'), child: const Text('Recreate')),
              ElevatedButton(
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SecondPage())),
                child: const Text('Push page'),
              ),
            ],
          ),
          Expanded(
            child: InAppWebView(
              key: ValueKey('home-$_gen'),
              initialData: InAppWebViewInitialData(data: '<h1>home gen $_gen</h1>'),
              initialSettings: _settings,
              onWebViewCreated: (_) {
                log('home onWebViewCreated gen=$_gen');
                _channel.invokeMethod('remember');
              },
              onLoadStop: (_, url) {
                log('home onLoadStop gen=$_gen');
                if (_gen == 0) {
                  _firstLoaded = true;
                  _autorun();
                }
              },
              onRenderProcessGone: (_, d) => _onRenderProcessGone(d),
            ),
          ),
        ],
      ),
    );
  }
}

class SecondPage extends StatefulWidget {
  const SecondPage({super.key});

  @override
  State<SecondPage> createState() => _SecondPageState();
}

class _SecondPageState extends State<SecondPage> {
  bool _popped = false;

  @override
  void dispose() {
    _secondDisposed?.complete();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('second')),
      body: InAppWebView(
        initialData: InAppWebViewInitialData(data: '<h1>second page</h1>'),
        initialSettings: _settings,
        onWebViewCreated: (_) {
          log('second onWebViewCreated');
          _channel.invokeMethod('remember');
        },
        onLoadStop: (_, url) async {
          await log('second onLoadStop');
          if (_secondLoaded?.isCompleted == false) _secondLoaded!.complete();
          // Auto mode (scenario C): leave the page as soon as it has loaded.
          final c = await _channel.invokeMapMethod<String, dynamic>('getConfig');
          if (c?['scenario'] == 'C' && !_popped && context.mounted) {
            _popped = true;
            Navigator.of(context).pop();
          }
        },
        onRenderProcessGone: (_, d) => log('second onRenderProcessGone didCrash=${d.didCrash}'),
      ),
    );
  }
}
