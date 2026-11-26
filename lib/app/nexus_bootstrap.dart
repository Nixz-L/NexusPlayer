import "package:material_ui/material_ui.dart";
import "../screens/home_screen.dart";
import "../src/rust/frb_generated.dart";

class NexusBootstrap extends StatefulWidget {
  const NexusBootstrap({super.key});

  @override
  State<NexusBootstrap> createState() => _NexusBootstrapState();
}

class _NexusBootstrapState extends State<NexusBootstrap> {
  late final Future<void> _rustInitialization = RustLib.init();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF08070D),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF9B6DFF),
          secondary: Color(0xFFB69AFF),
          surface: Color(0xFF15131D),
        ),
        useMaterial3: true,
        fontFamily: "Roboto",
      ),
      home: FutureBuilder<void>(
        future: _rustInitialization,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Scaffold(
              body: Center(
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Text(
                    "Não foi possível inicializar o núcleo Nexus.\n\n${snapshot.error}",
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            );
          }

          if (snapshot.connectionState != ConnectionState.done) {
            return const Scaffold(
              body: Center(
                child: CircularProgressIndicator(
                  color: Color(0xFF9B6DFF),
                ),
              ),
            );
          }

          return const NexusHomeScreen();
        },
      ),
    );
  }
}

