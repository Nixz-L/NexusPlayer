import "package:material_ui/material_ui.dart";
import "src/rust/api.dart";
import "src/rust/frb_generated.dart";

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const NexusBridgeTestApp());
}

class NexusBridgeTestApp extends StatefulWidget {
  const NexusBridgeTestApp({super.key});

  @override
  State<NexusBridgeTestApp> createState() => _NexusBridgeTestAppState();
}

class _NexusBridgeTestAppState extends State<NexusBridgeTestApp> {
  late final Future<String> _version = _loadVersion();

  Future<String> _loadVersion() async {
    await RustLib.init();
    return getNexusVersion();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF08070D),
      ),
      home: Scaffold(
        body: Center(
          child: FutureBuilder<String>(
            future: _version,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Text(
                  "ERRO: ${snapshot.error}",
                  textAlign: TextAlign.center,
                );
              }
              if (!snapshot.hasData) {
                return const CircularProgressIndicator();
              }
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    "NEXUS",
                    style: TextStyle(fontSize: 32, letterSpacing: 8),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    "RUST BRIDGE CONECTADA",
                    style: TextStyle(color: Colors.greenAccent),
                  ),
                  const SizedBox(height: 8),
                  Text("Rust v${snapshot.data}"),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

