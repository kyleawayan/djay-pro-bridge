#include <LedControl.h>

// MAX7219: DIN=12, CLK=11, CS=10, 1 device
LedControl lc(12, 11, 10, 1);

char buf[32];
int bufIdx = 0;

// Parse a beat jump value string and write digits to the display.
// Returns the number of digit positions used.
// For fractions like "1/32", displays as 1.32 (numerator with DP + denominator).
// For whole numbers like "128", displays digits directly.
// digits[] receives the digit values (0-9), dps[] receives decimal point flags.
int parseValue(const char* val, byte digits[], bool dps[], int maxLen) {
  int len = 0;
  const char* slash = strchr(val, '/');

  if (slash) {
    // Fraction: numerator with DP, then denominator digits
    if (len < maxLen) {
      digits[len] = val[0] - '0';
      dps[len] = true;
      len++;
    }
    const char* d = slash + 1;
    while (*d && len < maxLen) {
      digits[len] = *d - '0';
      dps[len] = false;
      len++;
      d++;
    }
  } else {
    // Whole number
    const char* p = val;
    while (*p && len < maxLen) {
      digits[len] = *p - '0';
      dps[len] = false;
      len++;
      p++;
    }
  }
  return len;
}

// Display deck 1 value left-justified on digits 7-4 (physical left side)
void displayLeft(const char* val) {
  byte digits[4];
  bool dps[4];
  int len = parseValue(val, digits, dps, 4);

  for (int i = 0; i < 4; i++) {
    int digit = 7 - i;  // digit 7, 6, 5, 4
    if (i < len) {
      lc.setDigit(0, digit, digits[i], dps[i]);
    } else {
      lc.setChar(0, digit, ' ', false);
    }
  }
}

// Display deck 2 value right-justified on digits 3-0 (physical right side)
void displayRight(const char* val) {
  byte digits[4];
  bool dps[4];
  int len = parseValue(val, digits, dps, 4);

  // Right-justify: place last digit at position 0, working left
  for (int i = 0; i < 4; i++) {
    int digit = i;  // digit 0, 1, 2, 3
    int valIdx = len - 1 - i;
    if (valIdx >= 0) {
      lc.setDigit(0, digit, digits[valIdx], dps[valIdx]);
    } else {
      lc.setChar(0, digit, ' ', false);
    }
  }
}

// Parse "L<val>R<val>" and update display
void processMessage(const char* msg) {
  const char* lPtr = strchr(msg, 'L');
  const char* rPtr = strchr(msg, 'R');

  if (lPtr && rPtr && rPtr > lPtr) {
    // Extract left value (between L and R)
    char lVal[8];
    int lLen = rPtr - (lPtr + 1);
    if (lLen > 0 && lLen < (int)sizeof(lVal)) {
      memcpy(lVal, lPtr + 1, lLen);
      lVal[lLen] = '\0';
      displayLeft(lVal);
    }

    // Extract right value (after R)
    displayRight(rPtr + 1);
  }
}

void setup() {
  lc.shutdown(0, false);
  lc.setIntensity(0, 8);
  lc.clearDisplay(0);

  // Startup: all 8s with decimal points to test every segment
  for (int i = 0; i < 8; i++) {
    lc.setDigit(0, i, 8, true);
  }
  delay(500);
  lc.clearDisplay(0);

  Serial.begin(9600);
}

void loop() {
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
}
