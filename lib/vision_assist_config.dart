const sttLocale = 'en_IN';
const ttsLocale = 'en-IN';
const readCmd = 'read';
const currencyCmd = 'detect currency';
const objectCmd = 'detect objects';
const barcodeCmd = 'scanner';
const stopCmd = 'stop';
const scanStatus = 'Scanning text';
const currencyScanningStatus = 'Detecting currency';
const objectScanningStatus = 'Detecting objects';
const barcodeScanningStatus = 'Scanning barcode and price';
const noTextStatus = 'No text detected';
const noCurrencyStatus = 'No currency detected';
const noObjectsStatus = 'No clear objects detected';
const noBarcodeStatus = 'No barcode detected';
const startedMessage =
    'Vision Assist ready. Say read to scan, detect objects, detect currency, or scanner to scan a barcode.';
const flashOnCmd = 'flash on';
const flashOffCmd = 'flash off';
const flashOnFeedback = 'Flash turned on';
const flashOffFeedback = 'Flash turned off';
const currencyDetectedPrefix = 'Detected currency';
const objectsDetectedPrefix = 'Detected objects';
const barcodeDetectedPrefix = 'Detected barcode';
const priceDetectedPrefix = 'Possible price';

// SOS & Emergency
const sosCmd = 'emergency';
const sosStatus = 'Fetching location and sending emergency alert';
const emergencyCallCmd = 'call emergency';
const emergencyCallStatus = 'Calling emergency contact';
const sosConfigStatus =
    'Please configure your emergency contact in settings first';
const emergencyContactKey = 'emergency_contact_number';
