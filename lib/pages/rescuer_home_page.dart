import 'package:flutter/material.dart';
import 'home_page.dart';

class RescuerHomePage extends StatelessWidget {
  const RescuerHomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return const HomePage(isRescuerAccount: true);
  }
}
