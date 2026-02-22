import 'package:flutter/material.dart';
import 'login_page.dart';
import 'location_permission_page.dart';

class RegisterPage extends StatelessWidget {
  const RegisterPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 30.0),
          child: Column(
            children: [
              const SizedBox(height: 50),
              // Updated Logo to match Onboarding
              Container(
                padding: const EdgeInsets.all(16),
                decoration: const BoxDecoration(
                  color: Color(0xFF1A60FF),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.waves, // Matches main.dart
                  size: 40,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 32),
              const Text(
                'FLOOTE',
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF0D1B3E),
                ),
              ),
              const SizedBox(height: 32),
              Container(
                height: 50,
                decoration: BoxDecoration(
                  color: const Color(0xFFF1F3F6),
                  borderRadius: BorderRadius.circular(25),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: GestureDetector(
                        onTap: () => Navigator.pushReplacement(
                          context,
                          MaterialPageRoute(
                            builder: (context) => const LoginPage(),
                          ),
                        ),
                        child: const Center(
                          child: Text(
                            'Login',
                            style: TextStyle(
                              color: Colors.grey,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ),
                    Expanded(child: _buildActiveTab('Register')),
                  ],
                ),
              ),
              const SizedBox(height: 32),
              _buildInputField(label: 'Email', hint: 'your.email@example.com'),
              const SizedBox(height: 20),
              _buildInputField(label: 'Phone Number', hint: '+63 XXX XXX XXXX'),
              const SizedBox(height: 20),
              _buildInputField(
                label: 'Password',
                hint: '••••••••',
                isPassword: true,
              ),
              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const LocationPermissionPage(),
                    ),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1A60FF),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text(
                    'Create Account',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildActiveTab(String label) {
    return Container(
      margin: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(21),
        boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 4)],
      ),
      child: Center(
        child: Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
      ),
    );
  }

  Widget _buildInputField({
    required String label,
    required String hint,
    bool isPassword = false,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        ),
        const SizedBox(height: 8),
        TextField(
          obscureText: isPassword,
          decoration: InputDecoration(
            hintText: hint,
            filled: true,
            fillColor: const Color(0xFFF5F7F9),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide.none,
            ),
          ),
        ),
      ],
    );
  }
}
