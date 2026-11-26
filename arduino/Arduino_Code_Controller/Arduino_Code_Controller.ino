const byte axisPins[] = {A0, A1, A2, A3};
const bool invertAxis[] = {false, false, false, false};
const int deadZone = 140;

const unsigned long debounceMs = 15;
const unsigned long tapMs = 100;
const unsigned long reportMs = 10;

struct Button {
  byte pin;
  bool rawPressed;
  bool pressed;
  unsigned long changedAt;

  bool update(unsigned long now) {
    const bool down = digitalRead(pin) == LOW;

    if (down != rawPressed) {
      rawPressed = down;
      changedAt = now;
    }

    if (rawPressed != pressed && now - changedAt >= debounceMs) {
      pressed = rawPressed;
      return pressed;  // True only when a new press is confirmed.
    }

    return false;
  }
};

Button jump = {10};
Button actionE = {6};
Button actionF = {3};

int center[4];
bool eTap = false;
bool fTap = false;
unsigned long eTapAt = 0;
unsigned long fTapAt = 0;
unsigned long lastReportAt = 0;

void setup() {
  pinMode(jump.pin, INPUT_PULLUP);
  pinMode(actionE.pin, INPUT_PULLUP);
  pinMode(actionF.pin, INPUT_PULLUP);
  Serial.begin(115200);

  // Leave both sticks centered while the Uno starts.
  for (byte axis = 0; axis < 4; ++axis) {
    long total = 0;
    for (byte sample = 0; sample < 16; ++sample) {
      analogRead(axisPins[axis]);
      total += analogRead(axisPins[axis]);
    }
    center[axis] = total / 16;
  }
}

void loop() {
  const unsigned long now = millis();
  jump.update(now);

  if (actionE.update(now)) {
    eTap = true;
    eTapAt = now;
  }

  if (actionF.update(now)) {
    fTap = true;
    fTapAt = now;
  }

  if (eTap && now - eTapAt >= tapMs) eTap = false;
  if (fTap && now - fTapAt >= tapMs) fTap = false;

  if (now - lastReportAt < reportMs) return;
  lastReportAt = now;

  // Bridge bit order: A, D, W, S, Left, Right, camera up/down, Space, F, E.
  unsigned int keys = 0;

  for (byte axis = 0; axis < 4; ++axis) {
    analogRead(axisPins[axis]);
    int offset = analogRead(axisPins[axis]) - center[axis];

    if (invertAxis[axis]) offset = -offset;
    if (offset < -deadZone) keys |= 1U << (2 * axis);
    if (offset > deadZone) keys |= 1U << (2 * axis + 1);
  }

  if (jump.pressed) keys |= 1U << 8;
  if (fTap) keys |= 1U << 9;
  if (eTap) keys |= 1U << 10;

  Serial.print(F("GC,"));
  Serial.println(keys);
}