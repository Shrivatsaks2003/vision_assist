const sttLocale = 'en_IN';
const ttsLocale = 'en-IN';
const kannadaTtsLocale = 'kn-IN';
const hindiTtsLocale = 'hi-IN';
const readCmd = 'read';
const readAreaCmd = 'read area';
const readSelectedCmd = 'read selected';
const currencyCmd = 'detect currency';
const objectCmd = 'detect objects';
const priceCmd = 'detect price';
const stopCmd = 'stop';
const timeCmd = 'time';
const dateCmd = 'date';
const dayCmd = 'day';
const navOnCmd = 'navigation mode on';
const navOffCmd = 'navigation mode off';
const scanStatus = 'Scanning text';
const currencyScanningStatus = 'Detecting currency';
const objectScanningStatus = 'Detecting objects';
const priceScanningStatus = 'Detecting price';
const noTextStatus = 'No text detected';
const noCurrencyStatus = 'No currency detected';
const noObjectsStatus = 'No clear objects detected';
const noPriceStatus = 'No price detected';
const startedMessage =
    'Voice Guide ready. Say time, date, day, read, detect objects, or detect currency.';
const navStartedStatus = 'Navigation mode on. I will guide you through obstacles.';
const navStoppedStatus = 'Navigation mode off.';
const flashOnCmd = 'flash on';
const flashOffCmd = 'flash off';
const flashOnFeedback = 'Flash turned on';
const flashOffFeedback = 'Flash turned off';
const currencyDetectedPrefix = 'Detected currency';
const objectsDetectedPrefix = 'Detected objects';
const priceDetectedPrefix = 'Detected price';

// SOS & Emergency
const sosCmd = 'emergency';
const sosStatus = 'Fetching location and sending emergency alert';
const emergencyCallCmd = 'call emergency';
const emergencyCallStatus = 'Calling emergency contact';
const sosConfigStatus =
    'Please configure your emergency contact in settings first';
const emergencyContactKey = 'emergency_contact_number';

enum CommandIntent {
  read,
  readArea,
  readSelected,
  detectCurrency,
  detectObjects,
  detectPrice,
  stop,
  time,
  date,
  day,
  navOn,
  navOff,
  emergency,
  callEmergency,
  flashOn,
  flashOff,
  next,
  none
}

const Map<CommandIntent, List<String>> commandRegistry = {
  CommandIntent.read: [readCmd, 'scan text', 'read this'],
  CommandIntent.readArea: [readAreaCmd, 'scan area', 'read selected area'],
  CommandIntent.readSelected: [readSelectedCmd, 'read this area', 'scan selected'],
  CommandIntent.detectCurrency: [currencyCmd, 'detect money', 'detect note', 'currency detect'],
  CommandIntent.detectObjects: [objectCmd, 'what is around me', 'scan objects', 'detect object'],
  CommandIntent.detectPrice: [priceCmd, 'scan price', 'check price', 'what is the price'],
  CommandIntent.stop: [stopCmd, 'cancel', 'pause', 'quit'],
  CommandIntent.time: [timeCmd, 'what time', 'tell time', 'time please'],
  CommandIntent.date: [dateCmd, 'today date', 'what is the date', 'today\'s date'],
  CommandIntent.day: [dayCmd, 'today day', 'what day', 'what is the day'],
  CommandIntent.navOn: [navOnCmd, 'start navigation', 'turn on navigation', 'navigation on'],
  CommandIntent.navOff: [navOffCmd, 'stop navigation', 'turn off navigation', 'navigation off'],
  CommandIntent.emergency: [sosCmd, 'help', 'sos', 'save me'],
  CommandIntent.callEmergency: [emergencyCallCmd, 'emergency call', 'call help', 'call sos'],
  CommandIntent.flashOn: [flashOnCmd, 'torch on', 'light on', 'turn on light'],
  CommandIntent.flashOff: [flashOffCmd, 'torch off', 'light off', 'turn off light'],
  CommandIntent.next: ['next', 'continue', 'more', 'next chunk'],
};
