import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_typeahead/flutter_typeahead.dart'; // Ensure this is in pubspec.yaml

class EmergencyPage extends StatefulWidget {
  const EmergencyPage({super.key});

  @override
  State<EmergencyPage> createState() => _EmergencyPageState();
}

class _EmergencyPageState extends State<EmergencyPage> {
  final TextEditingController _descriptionController = TextEditingController();
  final TextEditingController _locationController = TextEditingController();
  final ImagePicker _picker = ImagePicker();
  XFile? _selectedImage;
  bool _isSubmitting = false;
  bool _isDetectingLocation = true;

  double? _lat;
  double? _lng;

  @override
  void initState() {
    super.initState();
    _initLocationDetection();
  }

  // --- SEARCH METHOD: Borrowed from HomePage ---
  Future<List<Map<String, dynamic>>> _getSearchSuggestions(String query) async {
    if (query.length < 3) return [];
    
    // Limits results to Cebu area specifically
    final url = 'https://nominatim.openstreetmap.org/search'
        '?q=$query&format=json&limit=5&addressdetails=1'
        '&countrycodes=ph&viewbox=123.75,10.45,124.0,10.22&bounded=1'; 

    try {
      final response = await http.get(
        Uri.parse(url),
        headers: {'User-Agent': 'Floote_App_Emergency'},
      );

      if (response.statusCode == 200) {
        final List data = json.decode(response.body);
        return data.where((item) {
          final String address = item['display_name'].toString().toLowerCase();
          return address.contains('cebu');
        }).toList().cast<Map<String, dynamic>>();
      }
    } catch (e) {
      debugPrint("Search Error: $e");
    }
    return [];
  }

  // --- AUTO-DETECT ADDRESS FROM GPS ---
  Future<void> _initLocationDetection() async {
    setState(() => _isDetectingLocation = true);
    try {
      Position position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      );
      
      _lat = position.latitude;
      _lng = position.longitude;

      final url = Uri.parse(
          'https://nominatim.openstreetmap.org/reverse?format=json&lat=$_lat&lon=$_lng&zoom=18');
      
      final response = await http.get(url, headers: {'User-Agent': 'Floote_App'});

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        setState(() {
          _locationController.text = data['display_name'] ?? "Current Location";
          _isDetectingLocation = false;
        });
      }
    } catch (e) {
      debugPrint("Address detection error: $e");
      setState(() {
        _locationController.text = "";
        _isDetectingLocation = false;
      });
    }
  }

  Future<void> _pickImage() async {
    final XFile? image = await _picker.pickImage(source: ImageSource.gallery);
    if (image != null) setState(() => _selectedImage = image);
  }

  Future<void> _submitReport() async {
    if (_descriptionController.text.trim().isEmpty || _locationController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Description and Location are required.")),
      );
      return;
    }

    setState(() => _isSubmitting = true);

    try {
      String? publicUrl;

      if (_selectedImage != null) {
        final file = File(_selectedImage!.path);
        final fileName = 'report_${DateTime.now().millisecondsSinceEpoch}.jpg';
        await Supabase.instance.client.storage.from('reports').upload(fileName, file);
        publicUrl = Supabase.instance.client.storage.from('reports').getPublicUrl(fileName);
      }

      await Supabase.instance.client.from('user_reports').insert({
        'location_name': _locationController.text.trim(),
        'user_comments': _descriptionController.text.trim(),
        'image_url': publicUrl,
        'latitude': _lat,
        'longitude': _lng,
        'created_at': DateTime.now().toIso8601String(),
        'admin_decision': 'Pending',
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Report submitted!"), backgroundColor: Colors.green),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      debugPrint("Submit Error: $e");
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(icon: const Icon(Icons.close, color: Colors.black), onPressed: () => Navigator.pop(context)),
        title: const Text("Emergency SOS", style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildEmergencyContactsSection(),
            const SizedBox(height: 30),
            const Text("Report Incident", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            
            // --- EDITABLE SEARCHABLE LOCATION FIELD ---
            const Text("Location *", style: TextStyle(fontWeight: FontWeight.w500)),
            const SizedBox(height: 8),
            TypeAheadField<Map<String, dynamic>>(
              builder: (context, controller, focusNode) => TextField(
                controller: controller,
                focusNode: focusNode,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.location_on, color: Colors.red),
                  suffixIcon: _isDetectingLocation 
                      ? const Padding(padding: EdgeInsets.all(12), child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))) 
                      : IconButton(icon: const Icon(Icons.my_location), onPressed: _initLocationDetection),
                  hintText: "Type street name or use GPS...",
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  filled: true,
                  fillColor: Colors.green.shade50,
                ),
              ),
              suggestionsCallback: (pattern) async => await _getSearchSuggestions(pattern),
              itemBuilder: (context, suggestion) => ListTile(
                leading: const Icon(Icons.map, size: 20),
                title: Text(suggestion['display_name'], style: const TextStyle(fontSize: 12)),
              ),
              onSelected: (suggestion) {
                setState(() {
                  _locationController.text = suggestion['display_name'];
                  _lat = double.parse(suggestion['lat']);
                  _lng = double.parse(suggestion['lon']);
                });
              },
              controller: _locationController,
            ),
            
            const SizedBox(height: 20),
            const Text("Description *", style: TextStyle(fontWeight: FontWeight.w500)),
            const SizedBox(height: 8),
            TextField(
              controller: _descriptionController,
              maxLines: 3,
              decoration: InputDecoration(
                hintText: "Describe the water level or blockage...",
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
            
            const SizedBox(height: 20),
            const Text("Incident Photo", style: TextStyle(fontWeight: FontWeight.w500)),
            const SizedBox(height: 8),
            GestureDetector(
              onTap: _pickImage,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 30),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.blue.shade200),
                  borderRadius: BorderRadius.circular(10),
                  color: Colors.blue.shade50.withValues(alpha: 0.3),
                ),
                child: _selectedImage == null
                    ? const Column(children: [Icon(Icons.camera_alt, color: Colors.blue), Text("Tap to take/upload photo", style: TextStyle(color: Colors.blue, fontWeight: FontWeight.bold))])
                    : Column(children: [const Icon(Icons.check_circle, color: Colors.green), Text(_selectedImage!.name, style: const TextStyle(fontSize: 12))]),
              ),
            ),
            
            const SizedBox(height: 30),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue.shade700,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 15),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: _isSubmitting ? null : _submitReport,
                child: _isSubmitting 
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)) 
                  : const Text("SUBMIT REPORT", style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmergencyContactsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text("Emergency Contacts", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 16),
        GridView.count(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisCount: 2,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 1.5,
          children: [
            _buildContactCard("Emergency 911", "911", Colors.red, Icons.notifications_active),
            _buildContactCard("Cebu City Emergency", "161", Colors.blue, Icons.local_hospital),
          ],
        ),
      ],
    );
  }

  Widget _buildContactCard(String title, String subtitle, Color color, IconData icon) {
    return Container(
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(10)),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: Colors.white, size: 24),
          const SizedBox(height: 4),
          Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
          Text(subtitle, style: const TextStyle(color: Colors.white, fontSize: 10)),
        ],
      ),
    );
  }
}