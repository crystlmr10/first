import 'dart:async';
import 'package:flutter/material.dart';
import 'pages/login_page.dart';
import 'pages/rescuer_login_page.dart'; // Ensure this exists

void main() {
  runApp(const FlooteApp());
}

class FlooteApp extends StatelessWidget {
  const FlooteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: FlooteOnboarding(),
    );
  }
}

class FlooteOnboarding extends StatefulWidget {
  const FlooteOnboarding({super.key});

  @override
  State<FlooteOnboarding> createState() => _FlooteOnboardingState();
}

class _FlooteOnboardingState extends State<FlooteOnboarding> {
  // Logic for hidden rescuer access
  int _tapCount = 0;
  Timer? _tapTimer;

  void _handleLogoTap() {
    _tapTimer?.cancel();

    setState(() {
      _tapCount++;
    });

    if (_tapCount == 5) {
      _tapCount = 0;
      Navigator.push(
        context,
        MaterialPageRoute(builder: (context) => const RescuerLoginPage()),
      );
    } else {
      // Reset if no follow-up tap occurs within 2 seconds
      _tapTimer = Timer(const Duration(seconds: 2), () {
        setState(() {
          _tapCount = 0;
        });
      });
    }
  }

  @override
  void dispose() {
    _tapTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        width: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF1A60FF), Color(0xFF0D3EAD)],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24.0),
            child: Column(
              children: [
                const SizedBox(height: 40),
                // HIDDEN GESTURE WRAPPER ON LOGO
                GestureDetector(
                  onTap: _handleLogoTap,
                  child: const Icon(Icons.waves, size: 80, color: Colors.white),
                ),
                const SizedBox(height: 20),
                const Text(
                  'Welcome to Floote',
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Real-time flood detection for a safer commute',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 16, color: Colors.white70),
                ),
                const SizedBox(height: 40),
                _buildFeatureCard(
                  Icons.location_on_outlined,
                  'Live Flood Data',
                  'Real-time updates from LoRa sensors across Cebu City',
                ),
                const SizedBox(height: 16),
                _buildFeatureCard(
                  Icons.shield_outlined,
                  'Safe Routes',
                  'Navigate around flooded areas automatically',
                ),
                const SizedBox(height: 16),
                _buildFeatureCard(
                  Icons.water_outlined,
                  'Water Levels',
                  'Know before you go with accurate depth readings',
                ),
                const Spacer(),
                SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: ElevatedButton(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const LoginPage(),
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: const Color(0xFF1A60FF),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text(
                      'Get Started',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFeatureCard(IconData icon, String title, String desc) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white24),
      ),
      child: Column(
        children: [
          Icon(icon, color: Colors.white, size: 28),
          const SizedBox(height: 12),
          Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            desc,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
        ],
      ),
    );
  }
}
