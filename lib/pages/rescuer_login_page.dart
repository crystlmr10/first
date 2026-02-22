import 'package:flutter/material.dart';

class RescuerLoginPage extends StatelessWidget {
  const RescuerLoginPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1B263B), // Dark Navy Theme
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 30.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Rescuer Shield Icon
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.05),
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFF1A60FF), width: 1),
                ),
                child: const Icon(
                  Icons.shield_outlined,
                  size: 60,
                  color: Color(0xFF1A60FF),
                ),
              ),
              const SizedBox(height: 40),
              const Text(
                'Rescuer Access',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const Text(
                'Emergency Response Portal',
                style: TextStyle(color: Colors.white70, fontSize: 16),
              ),
              const SizedBox(height: 40),

              _buildRescuerInput(Icons.person_outline, 'Rescuer ID'),
              const SizedBox(height: 20),
              _buildRescuerInput(
                Icons.lock_outline,
                'Password',
                isPassword: true,
              ),

              const SizedBox(height: 40),

              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: () {}, // Rescuer Login Logic
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1A60FF),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text(
                    'Access Portal',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 30),

              // Restriction Notice
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white10),
                ),
                child: const Text(
                  'This portal is restricted to authorized emergency responders only. Unauthorized access is prohibited.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white54, fontSize: 13),
                ),
              ),
              const Spacer(),
              const Text(
                'Cebu City Emergency Response',
                style: TextStyle(color: Colors.white24, fontSize: 12),
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRescuerInput(
    IconData icon,
    String label, {
    bool isPassword = false,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          obscureText: isPassword,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            prefixIcon: Icon(icon, color: Colors.white38),
            hintText: 'Enter your ${label.toLowerCase()}',
            hintStyle: const TextStyle(color: Colors.white24),
            filled: true,
            fillColor: Colors.white.withValues(alpha: 0.05),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Colors.white10),
            ),
          ),
        ),
      ],
    );
  }
}
