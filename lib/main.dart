import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'pages/login_page.dart';
import 'pages/rescuer_login_page.dart';

// --- GLOBAL KEY FOR ALERTS ---
final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 3. Initialize Supabase
  await   .initialize(
    url: 'http://136.111.137.86:8000',
    anonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjoiYW5vbiIsImlzcyI6InN1cGFiYXNlIiwiaWF0IjoxNzczNjMyMDI2LCJleHAiOjE5MzEzMTIwMjZ9.3F7YOLt761b6G1OkIlDTG_70BNUMTe8nt5fnsBN98dY',
  );

  runApp(const FlooteApp());
}

class FlooteApp extends StatelessWidget {
  const FlooteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      // 4. Apply the Messenger Key
      scaffoldMessengerKey: scaffoldMessengerKey,
      debugShowCheckedModeBanner: false,
      title: 'Floote',
      theme: ThemeData(
        useMaterial3: true,
        primarySwatch: Colors.blue,
      ),
      home: const FlooteOnboarding(),
    );
  }
}

// --- ONBOARDING UI (Kept your animated design) ---
class FlooteOnboarding extends StatefulWidget {
  const FlooteOnboarding({super.key});

  @override
  State<FlooteOnboarding> createState() => _FlooteOnboardingState();
}

class _FlooteOnboardingState extends State<FlooteOnboarding>
    with TickerProviderStateMixin {
  int _tapCount = 0;
  Timer? _tapTimer;
  late final AnimationController _bgController;
  late final AnimationController _entryController;
  late final Animation<double> _titleFade;
  late final Animation<Offset> _titleSlide;

  void _handleLogoTap() {
    _tapTimer?.cancel();
    setState(() => _tapCount++);

    if (_tapCount == 5) {
      _tapCount = 0;
      Navigator.push(
        context,
        MaterialPageRoute(builder: (context) => const RescuerLoginPage()),
      );
    } else {
      _tapTimer = Timer(const Duration(seconds: 2), () {
        setState(() => _tapCount = 0);
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _bgController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3800),
    )..repeat(reverse: true);
    
    _entryController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..forward();

    _titleFade = CurvedAnimation(parent: _entryController, curve: Curves.easeOut);
    _titleSlide = Tween<Offset>(
      begin: const Offset(0, 0.07),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _entryController, curve: Curves.easeOut));
  }

  @override
  void dispose() {
    _tapTimer?.cancel();
    _bgController.dispose();
    _entryController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // Background Gradient
          Container(
            width: double.infinity,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF0A4DD3), Color(0xFF09235C)],
              ),
            ),
          ),
          
          // Floating Animated Orbs
          AnimatedBuilder(
            animation: _bgController,
            builder: (context, child) {
              return Stack(
                children: [
                  Positioned(
                    top: -90 + (40 * _bgController.value),
                    right: -50,
                    child: _buildOrb(size: 240, color: Colors.cyanAccent.withAlpha(58)),
                  ),
                  Positioned(
                    bottom: -110,
                    left: -30 + (25 * _bgController.value),
                    child: _buildOrb(size: 280, color: Colors.lightBlueAccent.withAlpha(48)),
                  ),
                ],
              );
            },
          ),

          // Main Content
          SafeArea(
            child: FadeTransition(
              opacity: _titleFade,
              child: SlideTransition(
                position: _titleSlide,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24.0),
                  child: Column(
                    children: [
                      const SizedBox(height: 34),
                      _buildLogo(),
                      const SizedBox(height: 20),
                      const Text(
                        'Welcome to Floote',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 34,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 10),
                      const Text(
                        'Real-time flood detection for a safer commute',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 16, color: Colors.white70),
                      ),
                      const SizedBox(height: 28),
                      _buildFeatureCard(Icons.location_on_outlined, 'Live Flood Data', 'Updates from sensors in Talisay, Tabunok, and Minglanilla'),
                      const SizedBox(height: 14),
                      _buildFeatureCard(Icons.shield_outlined, 'Safe Routes', 'Navigate around flooded areas automatically'),
                      const SizedBox(height: 14),
                      _buildFeatureCard(Icons.water_drop_outlined, 'Water Level Alerts', 'Track rising levels and get warned before roads become impassable'),
                      const Spacer(),
                      _buildGetStartedButton(context),
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLogo() {
    return GestureDetector(
      onTap: _handleLogoTap,
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white.withAlpha(26),
          border: Border.all(color: Colors.white30),
        ),
        child: const Icon(Icons.waves, size: 56, color: Colors.white),
      ),
    );
  }

  Widget _buildGetStartedButton(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: ElevatedButton(
        onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (context) => const LoginPage())),
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.white,
          foregroundColor: const Color(0xFF0A4DD3),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        child: const Text('Get Started', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
      ),
    );
  }

  Widget _buildOrb({required double size, required Color color}) {
    return Container(width: size, height: size, decoration: BoxDecoration(shape: BoxShape.circle, color: color));
  }

  Widget _buildFeatureCard(IconData icon, String title, String desc) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(24),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white30),
      ),
      child: Column(
        children: [
          Icon(icon, color: Colors.white, size: 28),
          const SizedBox(height: 12),
          Text(title, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(desc, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70, fontSize: 13)),
        ],
      ),
    );
  }
}