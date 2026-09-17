/*
 * Shhlock Key — firmware for the Seeed Studio XIAO ESP32C3 (v2: the vault lives on the key)
 *
 * The key holds the encrypted vault and answers paired devices directly:
 *
 *   phone (Shhlock app)      — loads and edits the vault, approves new computers    → PHONE_RX / PHONE_TX
 *   computer (menu-bar app)  — asks "logins for github.com?" and fills the form     → COMPUTER_RX / COMPUTER_TX
 *
 * Every message is sealed end-to-end (P-256 + AES-256-GCM). The vault key never sits in flash in the
 * clear: it is wrapped per paired device with a secret only that device holds, so a stolen key alone is
 * unreadable until a paired phone or computer connects and unlocks it.
 *
 * Button (BOOT, GPIO9): short press = confirm pairing a phone · hold 8 s = factory reset.
 *
 * Build with -DSHHLOCK_SERIAL_TEST to also speak the protocol over USB serial (tests only, never ship it).
 * Requires: esp32 core 3.x, NimBLE-Arduino 2.x, ArduinoJson 7.x
 */

#include <Arduino.h>
#include <NimBLEDevice.h>

#include "engine.h"

#define FW_VERSION "2.0.0"

#define UUID_SERVICE     "5afe0001-7a3c-4b1e-9d2f-c0de5afe1a00"
#define UUID_PHONE_RX    "5afe0002-7a3c-4b1e-9d2f-c0de5afe1a00"
#define UUID_PHONE_TX    "5afe0003-7a3c-4b1e-9d2f-c0de5afe1a00"
#define UUID_COMPUTER_RX "5afe0004-7a3c-4b1e-9d2f-c0de5afe1a00"
#define UUID_COMPUTER_TX "5afe0005-7a3c-4b1e-9d2f-c0de5afe1a00"
#define UUID_STATUS      "5afe0006-7a3c-4b1e-9d2f-c0de5afe1a00"

#define STATUS_PHONE     0x01
#define STATUS_COMPUTER  0x02
#define STATUS_UNLOCKED  0x04
#define STATUS_BUTTON    0x08  // waiting for the button to confirm a pairing

#define BUTTON_PIN 9
#define FRAME_SIZE 160
#define MAX_FRAME  244
#define IN_QUEUE   32
#define OUT_QUEUE  64

struct Frame {
  uint16_t conn;
  uint16_t len;
  uint8_t data[MAX_FRAME];
};

static NimBLEServer* server;
static NimBLECharacteristic *phoneTx, *computerTx, *statusCh;
static QueueHandle_t inQueue, outQueue;
static volatile bool statusDirty = true;
static uint8_t lastStatus = 0xFF;

// which characteristic each connection talks on, and who subscribed to what
struct Conn {
  bool used = false;
  uint16_t handle = 0;
  bool phoneSide = false;   // wrote on PHONE_RX
  bool phoneSub = false, computerSub = false;
};
static Conn conns[6];
static portMUX_TYPE connMux = portMUX_INITIALIZER_UNLOCKED;

static Conn* conn(uint16_t handle, bool create) {
  Conn* free_ = nullptr;
  for (Conn& c : conns) {
    if (c.used && c.handle == handle) return &c;
    if (!c.used && !free_) free_ = &c;
  }
  if (create && free_) {
    *free_ = Conn();
    free_->used = true;
    free_->handle = handle;
    return free_;
  }
  return nullptr;
}

// ── button ──

static volatile bool pressFlag = false;
static uint32_t pressedSince = 0;
static bool wasDown = false;

bool buttonWasPressed() {
  bool p = pressFlag;
  pressFlag = false;
  return p;
}

static void pollButton() {
  bool down = digitalRead(BUTTON_PIN) == LOW;
  uint32_t now = millis();
  if (down != wasDown) Serial.printf("[button] %s\n", down ? "down" : "up");
  if (down && !wasDown) pressedSince = now;
  if (!down && wasDown && now - pressedSince > 40 && now - pressedSince < 3000) pressFlag = true;
  if (down && wasDown && now - pressedSince > 8000) {
    Serial.println("[reset] button held 8 s — wiping vault and pairings");
    engine::factoryReset();
    statusDirty = true;
    pressedSince = now + 60000;  // do not repeat while still held
  }
  wasDown = down;
}

void statusChanged() { statusDirty = true; }

// ── transport ──

static void pumpOut();

void transmit(uint16_t handle, const Bytes& envelope) {
#ifdef SHHLOCK_SERIAL_TEST
  if (handle >= 0xFFF0) {
    Serial.printf("%c> %s\n", handle == 0xFFF0 ? 'P' : 'C', crypto::b64encode(envelope).c_str());
    return;
  }
#endif
  static uint8_t msgId = 0;
  msgId++;
  size_t payload = FRAME_SIZE - 3;
  size_t total = std::max((size_t)1, (envelope.size() + payload - 1) / payload);
  if (total > 255) return;
  for (size_t i = 0; i < total; i++) {
    Frame f;
    f.conn = handle;
    size_t start = i * payload, n = std::min(payload, envelope.size() - start);
    f.data[0] = msgId;
    f.data[1] = i;
    f.data[2] = total;
    memcpy(f.data + 3, envelope.data() + start, n);
    f.len = 3 + n;
    while (xQueueSend(outQueue, &f, 0) != pdTRUE) pumpOut();  // same task drains it; never deadlocks
  }
}

static void pumpOutImpl() {
  Frame f;
  while (xQueuePeek(outQueue, &f, 0) == pdTRUE) {
    NimBLECharacteristic* ch = nullptr;
    portENTER_CRITICAL(&connMux);
    Conn* c = conn(f.conn, false);
    if (c) ch = c->phoneSide ? phoneTx : computerTx;
    portEXIT_CRITICAL(&connMux);
    if (!ch) {
      xQueueReceive(outQueue, &f, 0);  // connection gone
      continue;
    }
    bool sent = false;
    for (int attempt = 0; attempt < 40 && !sent; attempt++) {
      sent = ch->notify(f.data, f.len, f.conn);
      if (!sent) delay(5);
    }
    xQueueReceive(outQueue, &f, 0);
    if (!sent) Serial.println("[tx] frame dropped after retries");
  }
}

static void pumpOut() { pumpOutImpl(); }

static uint8_t computeStatus() {
  uint8_t s = 0;
  portENTER_CRITICAL(&connMux);
  for (Conn& c : conns) {
    if (!c.used) continue;
    if (c.phoneSub) s |= STATUS_PHONE;
    if (c.computerSub) s |= STATUS_COMPUTER;
  }
  portEXIT_CRITICAL(&connMux);
  if (vault::unlocked()) s |= STATUS_UNLOCKED;
  if (engine::pairingWaitsForButton()) s |= STATUS_BUTTON;
  return s;
}

// ── BLE callbacks ──

class ServerCallbacks : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer* s, NimBLEConnInfo& info) override {
    portENTER_CRITICAL(&connMux);
    conn(info.getConnHandle(), true);
    portEXIT_CRITICAL(&connMux);
    // The centrals' own parameters (iOS/macOS use ~30 ms) work fine; asking for more made a second link flap.
    Serial.printf("[link] connected handle=%u peers=%u\n", info.getConnHandle(), s->getConnectedCount());
    if (s->getConnectedCount() < 5) NimBLEDevice::startAdvertising();
  }
  void onDisconnect(NimBLEServer* s, NimBLEConnInfo& info, int reason) override {
    portENTER_CRITICAL(&connMux);
    Conn* c = conn(info.getConnHandle(), false);
    if (c) c->used = false;
    portEXIT_CRITICAL(&connMux);
    engine::linkClosed(info.getConnHandle());
    statusDirty = true;
    Serial.printf("[link] disconnected handle=%u reason=0x%x (%s)\n", info.getConnHandle(), reason, c && c->phoneSide ? "phone side" : "computer side");
    NimBLEDevice::startAdvertising();
  }
  void onMTUChange(uint16_t mtu, NimBLEConnInfo& info) override {
    Serial.printf("[link] handle=%u mtu=%u\n", info.getConnHandle(), mtu);
  }
};

class RxCallbacks : public NimBLECharacteristicCallbacks {
 public:
  explicit RxCallbacks(bool phone) : phone(phone) {}
  void onWrite(NimBLECharacteristic* ch, NimBLEConnInfo& info) override {
    NimBLEAttValue v = ch->getValue();
    if (v.length() < 3 || v.length() > MAX_FRAME) return;
    portENTER_CRITICAL(&connMux);
    if (Conn* c = conn(info.getConnHandle(), true)) c->phoneSide = phone;
    portEXIT_CRITICAL(&connMux);
    Frame f;
    f.conn = info.getConnHandle();
    f.len = v.length();
    memcpy(f.data, v.data(), f.len);
    xQueueSend(inQueue, &f, 0);  // crypto runs in loop(), never inside the BLE task
  }
 private:
  bool phone;
};

class TxCallbacks : public NimBLECharacteristicCallbacks {
 public:
  explicit TxCallbacks(bool phone) : phone(phone) {}
  void onSubscribe(NimBLECharacteristic*, NimBLEConnInfo& info, uint16_t sub) override {
    portENTER_CRITICAL(&connMux);
    if (Conn* c = conn(info.getConnHandle(), true)) {
      if (phone) c->phoneSub = sub != 0; else c->computerSub = sub != 0;
      if (sub) c->phoneSide = phone;
    }
    portEXIT_CRITICAL(&connMux);
    statusDirty = true;
    Serial.printf("[role] handle=%u %s %s\n", info.getConnHandle(), phone ? "phone" : "computer", sub ? "joined" : "left");
  }
 private:
  bool phone;
};

// ── serial test transport ──

#ifdef SHHLOCK_SERIAL_TEST
static void pollSerialTest() {
  static String line;
  static bool reserved = false;
  if (!reserved) { line.reserve(8192); reserved = true; }
  while (Serial.available()) {
    char c = Serial.read();
    if (c == '\r') continue;
    if (c != '\n') { line += c; continue; }
    if (line == "BTN") pressFlag = true;
    else if (line == "RESET") { engine::factoryReset(); Serial.println("# reset"); }
    else if (line == "REBOOT") { Serial.println("# rebooting"); delay(50); ESP.restart(); }
    else if (line.length() > 2 && (line[0] == 'P' || line[0] == 'C') && line[1] == ' ') {
      uint16_t handle = line[0] == 'P' ? 0xFFF0 : 0xFFF1;
      Bytes env = crypto::b64decode(line.c_str() + 2);
      // run it through the same framing path as BLE
      size_t payload = FRAME_SIZE - 3, total = std::max((size_t)1, (env.size() + payload - 1) / payload);
      static uint8_t msgId = 0;
      msgId++;
      for (size_t i = 0; i < total; i++) {
        uint8_t frame[MAX_FRAME];
        size_t start = i * payload, n = std::min(payload, env.size() - start);
        frame[0] = msgId; frame[1] = i; frame[2] = total;
        memcpy(frame + 3, env.data() + start, n);
        engine::frameIn(handle, frame, 3 + n);
      }
    }
    line = "";
  }
}
#endif

// ── setup / loop ──

void setup() {
#ifdef SHHLOCK_SERIAL_TEST
  Serial.setRxBufferSize(32768);  // test transport sends whole envelopes as one line
#endif
  Serial.begin(115200);
  delay(300);
  Serial.printf("\nShhlock Key firmware %s\n", FW_VERSION);
  pinMode(BUTTON_PIN, INPUT_PULLUP);
  Serial.printf("[button] idle level %d (1 = released)\n", digitalRead(BUTTON_PIN));

  inQueue = xQueueCreate(IN_QUEUE, sizeof(Frame));
  outQueue = xQueueCreate(OUT_QUEUE, sizeof(Frame));

  if (!vault::begin()) Serial.println("[fs] LittleFS failed");
  engine::begin();
  Serial.printf("[id] %u paired device(s), vault file %s\n", (unsigned)engine::clients.size(), LittleFS.exists(vault::FILE_PATH) ? "present" : "absent");

  NimBLEDevice::init(KEY_NAME);
  NimBLEDevice::setMTU(247);
  NimBLEDevice::setPower(9);
  server = NimBLEDevice::createServer();
  server->setCallbacks(new ServerCallbacks());
  server->advertiseOnDisconnect(true);

  NimBLEService* svc = server->createService(UUID_SERVICE);
  NimBLECharacteristic* phoneRx = svc->createCharacteristic(UUID_PHONE_RX, NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR, MAX_FRAME);
  phoneTx = svc->createCharacteristic(UUID_PHONE_TX, NIMBLE_PROPERTY::NOTIFY, MAX_FRAME);
  NimBLECharacteristic* computerRx = svc->createCharacteristic(UUID_COMPUTER_RX, NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR, MAX_FRAME);
  computerTx = svc->createCharacteristic(UUID_COMPUTER_TX, NIMBLE_PROPERTY::NOTIFY, MAX_FRAME);
  statusCh = svc->createCharacteristic(UUID_STATUS, NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY, 1);
  phoneRx->setCallbacks(new RxCallbacks(true));
  computerRx->setCallbacks(new RxCallbacks(false));
  phoneTx->setCallbacks(new TxCallbacks(true));
  computerTx->setCallbacks(new TxCallbacks(false));
  uint8_t zero = 0;
  statusCh->setValue(&zero, 1);
  svc->start();

  NimBLEAdvertising* adv = NimBLEDevice::getAdvertising();
  adv->addServiceUUID(UUID_SERVICE);
  adv->setName(KEY_NAME);
  adv->enableScanResponse(true);
  adv->start();
  Serial.println("[ble] advertising");
#ifdef SHHLOCK_SERIAL_TEST
  Serial.println("# serial test transport enabled");
#endif
}

void loop() {
  Frame f;
  while (xQueueReceive(inQueue, &f, 0) == pdTRUE) engine::frameIn(f.conn, f.data, f.len);
  pumpOut();
  pollButton();
  engine::tick();
#ifdef SHHLOCK_SERIAL_TEST
  pollSerialTest();
#endif

  if (statusDirty) {
    statusDirty = false;
    uint8_t s = computeStatus();
    if (s != lastStatus) {
      lastStatus = s;
      statusCh->setValue(&s, 1);
      statusCh->notify();
      Serial.printf("[status] phone=%d computer=%d unlocked=%d button=%d\n", !!(s & STATUS_PHONE), !!(s & STATUS_COMPUTER), !!(s & STATUS_UNLOCKED), !!(s & STATUS_BUTTON));
    }
  }
  static uint32_t lastBeat = 0;
  if (millis() - lastBeat > 30000) {
    lastBeat = millis();
    Serial.printf("[beat] peers=%u logins=%u unlocked=%d heap=%lu btn=%d\n", server->getConnectedCount(), (unsigned)vault::items.size(), vault::unlocked(), (unsigned long)ESP.getFreeHeap(), digitalRead(BUTTON_PIN));
  }
  delay(2);
}
