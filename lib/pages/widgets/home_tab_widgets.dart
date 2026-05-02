import 'package:flutter/material.dart';

class HomeBottomNav extends StatelessWidget {
  final bool isRescuerAccount;
  final int currentIndex;
  final ValueChanged<int> onTap;
  final Color accentColor;

  const HomeBottomNav({
    super.key,
    required this.isRescuerAccount,
    required this.currentIndex,
    required this.onTap,
    required this.accentColor,
  });

  @override
  Widget build(BuildContext context) {
    final items = isRescuerAccount
        ? const [
            BottomNavigationBarItem(
              icon: Icon(Icons.dashboard_rounded),
              label: 'Dashboard',
            ),
            BottomNavigationBarItem(icon: Icon(Icons.explore), label: 'Map'),
            BottomNavigationBarItem(
              icon: Icon(Icons.location_on_outlined),
              label: 'Rescue',
            ),
            BottomNavigationBarItem(icon: Icon(Icons.person), label: 'Profile'),
          ]
        : const [
            BottomNavigationBarItem(icon: Icon(Icons.explore), label: 'Map'),
            BottomNavigationBarItem(
              icon: Icon(Icons.notifications),
              label: 'Alerts',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.report_problem_outlined),
              label: 'Reports',
            ),
            BottomNavigationBarItem(icon: Icon(Icons.person), label: 'Profile'),
          ];

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF101A24),
        border: Border(top: BorderSide(color: Colors.white.withAlpha(26))),
        boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 18)],
      ),
      child: BottomNavigationBar(
        backgroundColor: const Color(0xFF101A24),
        elevation: 0,
        selectedItemColor: accentColor,
        unselectedItemColor: Colors.blueGrey.shade300,
        type: BottomNavigationBarType.fixed,
        currentIndex: currentIndex,
        onTap: onTap,
        items: items,
      ),
    );
  }
}

class RescuerDashboardHeaderCard extends StatelessWidget {
  final bool isActiveDuty;
  final ValueChanged<bool> onDutyChanged;
  final Color accentColor;

  const RescuerDashboardHeaderCard({
    super.key,
    required this.isActiveDuty,
    required this.onDutyChanged,
    required this.accentColor,
  });

  @override
  Widget build(BuildContext context) {
    final String dutyLabel = isActiveDuty ? 'ACTIVE DUTY' : 'OFF DUTY';
    final Color dutyColor = isActiveDuty ? accentColor : Colors.blueGrey.shade300;

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 0),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFF111A24),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withAlpha(26)),
          boxShadow: const [
            BoxShadow(
              color: Color(0x14000000),
              blurRadius: 12,
              offset: Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          children: [
            const CircleAvatar(
              radius: 24,
              backgroundColor: Color(0xFFDCE6F5),
              child: Icon(Icons.person, color: Color(0xFF2A3C52), size: 28),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Sgt. C. Itu',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  SizedBox(height: 2),
                  Text(
                    'ID: TLY-01 (Talisay)',
                    style: TextStyle(color: Colors.white70, fontSize: 15),
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  dutyLabel,
                  style: TextStyle(
                    color: dutyColor,
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                  ),
                ),
                Switch(
                  value: isActiveDuty,
                  activeThumbColor: Colors.white,
                  activeTrackColor: accentColor,
                  inactiveThumbColor: Colors.white,
                  inactiveTrackColor: Colors.blueGrey.shade600,
                  onChanged: onDutyChanged,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
