#include <LedControl.h>

// MAX7219: DIN=12, CLK=11, CS=10, 1 device
LedControl lc(12, 11, 10, 1);

// 7-segment raw byte for 'i': just segment C (bottom-right stroke)
#define SEG_i 0x10

// Serial buffer
char buf[48];
int bufIdx = 0;

// Display state: 4 values + 2 loop-on flags
char val[4][8];       // bj1, lp1, lp2, bj2
bool loopOn[2];       // deck 1, deck 2

// Overlay state
char overlay[16];
unsigned long overlayEnd = 0;

// Loop flash
const unsigned long FLASH_INTERVAL = 300;
unsigned long lastFlash = 0;
bool flashOn = true;

// Display a value in a 2-digit section.
// hiDigit = leftmost digit index of the section (hiDigit, hiDigit-1).
// Fractions: denominator with DP on first digit (3.2 = 1/32).
// 128: show "Hi".
// Whole numbers: right-justified.
void displaySection(int hiDigit, const char* v) {
  int lo = hiDigit - 1;
  const char* slash = strchr(v, '/');

  if (strcmp(v, "128") == 0) {
    lc.setChar(0, hiDigit, 'H', false);
    lc.setRow(0, lo, SEG_i);
    return;
  }

  if (slash) {
    // Fraction: dot in front of denominator
    const char* denom = slash + 1;
    int dLen = strlen(denom);
    if (dLen == 1) {
      // .2 .4 .8 — blank with DP, then digit
      lc.setChar(0, hiDigit, ' ', true);
      lc.setDigit(0, lo, denom[0] - '0', false);
    } else {
      // 1.6 3.2 — DP between digits (best fit for 2 positions)
      lc.setDigit(0, hiDigit, denom[0] - '0', true);
      lc.setDigit(0, lo, denom[1] - '0', false);
    }
  } else {
    // Whole number, right-justified
    int len = strlen(v);
    if (len >= 2) {
      lc.setDigit(0, hiDigit, v[0] - '0', false);
      lc.setDigit(0, lo, v[1] - '0', false);
    } else if (len == 1) {
      lc.setChar(0, hiDigit, ' ', false);
      lc.setDigit(0, lo, v[0] - '0', false);
    } else {
      lc.setChar(0, hiDigit, ' ', false);
      lc.setChar(0, lo, ' ', false);
    }
  }
}

void blankSection(int hiDigit) {
  lc.setChar(0, hiDigit, ' ', false);
  lc.setChar(0, hiDigit - 1, ' ', false);
}

// Render the normal 4-section display
void renderDisplay() {
  // BJ1: digits 7-6
  displaySection(7, val[0]);
  // LP1: digits 5-4 (flash if loop on)
  if (loopOn[0] && !flashOn) {
    blankSection(5);
  } else {
    displaySection(5, val[1]);
  }
  // LP2: digits 3-2 (flash if loop on)
  if (loopOn[1] && !flashOn) {
    blankSection(3);
  } else {
    displaySection(3, val[2]);
  }
  // BJ2: digits 1-0
  displaySection(1, val[3]);
}

// Render overlay text: up to 8 chars, left-justified, digits only
void renderOverlay() {
  int len = strlen(overlay);
  for (int i = 0; i < 8; i++) {
    int digit = 7 - i;
    if (i < len) {
      char c = overlay[i];
      if (c >= '0' && c <= '9') {
        lc.setDigit(0, digit, c - '0', false);
      } else if (c == '.') {
        // Set DP on previous digit (handled below)
        lc.setChar(0, digit, ' ', false);
      } else if (c == ' ') {
        lc.setChar(0, digit, ' ', false);
      } else {
        lc.setChar(0, digit, c, false);
      }
    } else {
      lc.setChar(0, digit, ' ', false);
    }
  }
}

// Parse comma-separated fields from a string
int splitCSV(char* str, char* fields[], int maxFields) {
  int count = 0;
  char* tok = strtok(str, ",");
  while (tok && count < maxFields) {
    fields[count++] = tok;
    tok = strtok(NULL, ",");
  }
  return count;
}

// Process incoming message
void processMessage(char* msg) {
  if (msg[0] == 'D') {
    // Display state: D<bj1>,<lp1>,<lp2>,<bj2>,<l1on>,<l2on>
    char* fields[6];
    int n = splitCSV(msg + 1, fields, 6);
    if (n >= 6) {
      strncpy(val[0], fields[0], sizeof(val[0]) - 1);
      strncpy(val[1], fields[1], sizeof(val[1]) - 1);
      strncpy(val[2], fields[2], sizeof(val[2]) - 1);
      strncpy(val[3], fields[3], sizeof(val[3]) - 1);
      loopOn[0] = fields[4][0] == '1';
      loopOn[1] = fields[5][0] == '1';
    }
  } else if (msg[0] == 'T') {
    // Temporary overlay: T<text> (auto-clears after 2s)
    strncpy(overlay, msg + 1, sizeof(overlay) - 1);
    overlay[sizeof(overlay) - 1] = '\0';
    overlayEnd = millis() + 2000;
  } else if (msg[0] == 'O') {
    // Persistent overlay: O<text> (stays until cleared)
    strncpy(overlay, msg + 1, sizeof(overlay) - 1);
    overlay[sizeof(overlay) - 1] = '\0';
    overlayEnd = 0;  // no timeout
  } else if (msg[0] == 'C') {
    // Clear overlay
    overlay[0] = '\0';
    overlayEnd = 0;
  }
}

void setup() {
  lc.shutdown(0, false);
  lc.setIntensity(0, 8);
  lc.clearDisplay(0);

  // Defaults
  strcpy(val[0], "1");
  strcpy(val[1], "4");
  strcpy(val[2], "4");
  strcpy(val[3], "1");
  loopOn[0] = false;
  loopOn[1] = false;
  overlay[0] = '\0';

  // Startup: all 8s with decimal points to test every segment
  for (int i = 0; i < 8; i++) {
    lc.setDigit(0, i, 8, true);
  }
  delay(500);

  renderDisplay();
  Serial.begin(9600);
}

void loop() {
  // Read serial
  while (Serial.available()) {
    char c = Serial.read();
    if (c == '\n' || c == '\r') {
      if (bufIdx > 0) {
        buf[bufIdx] = '\0';
        processMessage(buf);
        bufIdx = 0;
      }
    } else if (bufIdx < (int)sizeof(buf) - 1) {
      buf[bufIdx++] = c;
    }
  }

  // Clear overlay after timeout
  if (overlayEnd > 0 && millis() >= overlayEnd) {
    overlayEnd = 0;
    overlay[0] = '\0';
  }

  // Update flash state
  unsigned long now = millis();
  if (now - lastFlash >= FLASH_INTERVAL) {
    lastFlash = now;
    flashOn = !flashOn;
  }

  // Render
  if (overlay[0] != '\0') {
    renderOverlay();
  } else {
    renderDisplay();
  }
}
