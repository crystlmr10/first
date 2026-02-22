import 'package:flutter/material.dart';

class ForgotPasswordPage extends StatelessWidget {
  const ForgotPasswordPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.black),
          onPressed: () {
            Navigator.pop(context); // Goes back to the Login page
          },
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 30.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 20),
              // Lock/Reset Icon
              Center(
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: const BoxDecoration(
                    color: Color(0xFFE3F2FD), // Light blue background
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.lock_reset_rounded,
                    size: 50,
                    color: Color(0xFF1A60FF),
                  ),
                ),
              ),
              const SizedBox(height: 32),

              // Title and Subtitle
              const Center(
                child: Text(
                  'Forgot Password?',
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF0D1B3E),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Enter the email address associated with your account and we will send you a link to reset your password.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 15,
                  color: Colors.blueGrey[600],
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 40),

              // Email Input Field
              const Text(
                'Email',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                  color: Colors.black,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                keyboardType: TextInputType.emailAddress,
                decoration: InputDecoration(
                  hintText: 'your.email@example.com',
                  hintStyle: TextStyle(color: Colors.grey[400]),
                  filled: true,
                  fillColor: const Color(0xFFF5F7F9),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 16,
                  ),
                ),
              ),
              const SizedBox(height: 32),

              // Send Reset Link Button
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: () {
                    // Add password reset logic here later
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Reset link sent to your email!'),
                      ),
                    );
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1A60FF),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    elevation: 0,
                  ),
                  child: const Text(
                    'Send Reset Link',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
