import 'package:flutter/material.dart';

class LocationPermissionPage extends StatelessWidget {
  const LocationPermissionPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 30.0),
          child: Column(
            children: [
              const Spacer(),
              Container(
                padding: const EdgeInsets.all(30),
                decoration: const BoxDecoration(
                  color: Color(0xFF1A60FF),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.location_on,
                  size: 64,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 40),
              const Text(
                'Enable Location',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF0D1B3E),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Allow Floote to access your location to provide real-time flood data for your current path',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 15,
                  color: Colors.blueGrey,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 48),
              _buildCheckItem(
                'Real-time Alerts',
                'Get notified about floods on your route',
              ),
              const SizedBox(height: 24),
              _buildCheckItem(
                'Automatic Rerouting',
                "We'll find safer alternatives instantly",
              ),
              const SizedBox(height: 24),
              _buildCheckItem(
                'Emergency Services',
                'Quick SOS access if you get stranded',
              ),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: () {
                    // Logic for Home Page after enabling location
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1A60FF),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text(
                    'Enable Location',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCheckItem(String title, String subtitle) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(
          Icons.check_circle_outline,
          color: Color(0xFF2E7D32),
          size: 28,
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF0D1B3E),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: const TextStyle(fontSize: 14, color: Colors.blueGrey),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
