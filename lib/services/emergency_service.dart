import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../vision_assist_config.dart';

class EmergencyService {
  Future<bool> triggerSOS() async {
    final prefs = await SharedPreferences.getInstance();
    final number = prefs.getString(emergencyContactKey);

    if (number == null || number.trim().isEmpty) {
      return false; // Contact not configured
    }

    // Check location permissions
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        return _launchSMS(number, 'SOS! I need help. (Location unavailable)');
      }
    }

    if (permission == LocationPermission.deniedForever) {
      return _launchSMS(
          number, 'SOS! I need help. (Location permission denied forever)');
    }

    // Get location
    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );
      final mapsUrl =
          'https://maps.google.com/?q=${position.latitude},${position.longitude}';
      final message = 'SOS! I need help. My current location is: $mapsUrl';
      return _launchSMS(number, message);
    } catch (e) {
      return _launchSMS(number, 'SOS! I need help. (Error fetching location)');
    }
  }

  Future<bool> _launchSMS(String number, String message) async {
    // For iOS compatibility, the body param must be properly encoded
    // Wait, url_launcher handles encoding when passing queryParameters.
    final Uri smsUri = Uri(
      scheme: 'sms',
      path: number,
      queryParameters: <String, String>{
        'body': message,
      },
    );
    try {
      if (await canLaunchUrl(smsUri)) {
        await launchUrl(smsUri);
        return true;
      }
    } catch (e) {
      // Ignored
    }
    return false;
  }

  Future<bool> callEmergencyContact() async {
    final prefs = await SharedPreferences.getInstance();
    final number = prefs.getString(emergencyContactKey);

    if (number == null || number.trim().isEmpty) {
      return false;
    }

    return _launchCall(number);
  }

  Future<bool> _launchCall(String number) async {
    final Uri telUri = Uri(
      scheme: 'tel',
      path: number,
    );

    try {
      if (await canLaunchUrl(telUri)) {
        await launchUrl(telUri);
        return true;
      }
    } catch (e) {
      // Ignored
    }
    return false;
  }
}
