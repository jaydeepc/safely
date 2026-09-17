/*
 * Shlok Key — firmware for the Seeed Studio XIAO ESP32C3
 *
 * The key is a BLE *relay*. Two kinds of centrals connect to it at the same time:
 *
 *   - the PHONE   (Shlok iOS app, holds the vault)
 *   - a BROWSER   (Shlok native host on the computer, on behalf of the Chrome extension)
 *
 * Roles are defined by which characteristics a central uses, not by the connection:
 *
 *   browser --write--> BROWSER_RX  ==relay==>  PHONE_TX   --notify--> phone
 *   phone   --write--> PHONE_RX    ==relay==>  BROWSER_TX --notify--> browser
 *
 * Every frame is forwarded untouched. Payloads are end-to-end encrypted between the
 * extension and the phone (ECDH P-256 + AES-256-GCM), so the key never sees a secret
 * and stores nothing. STATUS tells each side whether the other side is present.
 *
 * Requires: esp32 core 3.x, NimBLE-Arduino 2.x
 */

#include <Arduino.h>
#include <NimBLEDevice.h>

#define FW_VERSION "1.1.0"
#define DEVICE_NAME "Shlok Key"

#define UUID_SERVICE    "5afe0001-7a3c-4b1e-9d2f-c0de5afe1a00"
#define UUID_PHONE_RX   "5afe0002-7a3c-4b1e-9d2f-c0de5afe1a00"  // phone   -> key   (write)
#define UUID_PHONE_TX   "5afe0003-7a3c-4b1e-9d2f-c0de5afe1a00"  // key     -> phone (notify)
#define UUID_BROWSER_RX "5afe0004-7a3c-4b1e-9d2f-c0de5afe1a00"  // browser -> key   (write)
#define UUID_BROWSER_TX "5afe0005-7a3c-4b1e-9d2f-c0de5afe1a00"  // key     -> browser (notify)
#define UUID_STATUS     "5afe0006-7a3c-4b1e-9d2f-c0de5afe1a00"  // presence bitmask (read/notify)

#define STATUS_PHONE_PRESENT   0x01
#define STATUS_BROWSER_PRESENT 0x02

#define MAX_FRAME      244   // ATT payload at MTU 247
#define MAX_LINKS      4
#define QUEUE_DEPTH    48
#define NOTIFY_RETRIES 40

enum Direction : uint8_t { TO_PHONE = 0, TO_BROWSER = 1 };

struct Frame {
  uint8_t  dir;
  uint16_t len;
  uint8_t  data[MAX_FRAME];
};

struct Link {
  bool     used;
  uint16_t handle;
  bool     isPhone;
  bool     isBrowser;
};

static NimBLEServer*         server    = nullptr;
static NimBLECharacteristic* phoneTx   = nullptr;
static NimBLECharacteristic* browserTx = nullptr;
static NimBLECharacteristic* statusCh  = nullptr;

static QueueHandle_t frameQueue;
static Link          links[MAX_LINKS];
static portMUX_TYPE  linksMux     = portMUX_INITIALIZER_UNLOCKED;
static volatile bool statusDirty  = true;
static uint8_t       lastStatus   = 0xFF;
static uint32_t      relayedCount = 0;
static uint32_t      droppedCount = 0;

static Link* findLink(uint16_t handle, bool create) {
  Link* freeSlot = nullptr;
  for (auto& l : links) {
    if (l.used && l.handle == handle) return &l;
    if (!l.used && !freeSlot) freeSlot = &l;
  }
  if (create && freeSlot) {
    *freeSlot = { true, handle, false, false };
    return freeSlot;
  }
  return nullptr;
}

static uint8_t computeStatus() {
  uint8_t s = 0;
  portENTER_CRITICAL(&linksMux);
  for (auto& l : links) {
    if (!l.used) continue;
    if (l.isPhone)   s |= STATUS_PHONE_PRESENT;
    if (l.isBrowser) s |= STATUS_BROWSER_PRESENT;
  }
  portEXIT_CRITICAL(&linksMux);
  return s;
}

static void keepAdvertising() {
  if (server->getConnectedCount() < MAX_LINKS - 1) {
    NimBLEDevice::startAdvertising();
  }
}

class ServerCallbacks : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer* s, NimBLEConnInfo& info) override {
    portENTER_CRITICAL(&linksMux);
    findLink(info.getConnHandle(), true);
    portEXIT_CRITICAL(&linksMux);
    // 15–30 ms interval keeps a fill round-trip snappy and is within Apple's accessory limits.
    s->updateConnParams(info.getConnHandle(), 12, 24, 0, 400);
    Serial.printf("[link] connected handle=%u peers=%u\n", info.getConnHandle(), s->getConnectedCount());
    keepAdvertising();  // stay discoverable so the second central can join
  }

  void onDisconnect(NimBLEServer* s, NimBLEConnInfo& info, int reason) override {
    portENTER_CRITICAL(&linksMux);
    Link* l = findLink(info.getConnHandle(), false);
    if (l) l->used = false;
    portEXIT_CRITICAL(&linksMux);
    statusDirty = true;
    Serial.printf("[link] disconnected handle=%u reason=0x%x\n", info.getConnHandle(), reason);
    NimBLEDevice::startAdvertising();
  }

  void onMTUChange(uint16_t mtu, NimBLEConnInfo& info) override {
    Serial.printf("[link] handle=%u mtu=%u\n", info.getConnHandle(), mtu);
  }
};

class RelayCallbacks : public NimBLECharacteristicCallbacks {
 public:
  explicit RelayCallbacks(Direction d) : dir(d) {}

  void onWrite(NimBLECharacteristic* c, NimBLEConnInfo& info) override {
    NimBLEAttValue v = c->getValue();
    if (v.length() == 0 || v.length() > MAX_FRAME) return;
    Frame f;
    f.dir = dir;
    f.len = v.length();
    memcpy(f.data, v.data(), f.len);
    if (xQueueSend(frameQueue, &f, 0) != pdTRUE) droppedCount++;
  }

 private:
  Direction dir;
};

class PresenceCallbacks : public NimBLECharacteristicCallbacks {
 public:
  explicit PresenceCallbacks(bool phone) : phoneSide(phone) {}

  void onSubscribe(NimBLECharacteristic* c, NimBLEConnInfo& info, uint16_t subValue) override {
    portENTER_CRITICAL(&linksMux);
    Link* l = findLink(info.getConnHandle(), true);
    if (l) {
      if (phoneSide) l->isPhone = subValue != 0;
      else           l->isBrowser = subValue != 0;
    }
    portEXIT_CRITICAL(&linksMux);
    statusDirty = true;
    Serial.printf("[role] handle=%u %s %s\n", info.getConnHandle(),
                  phoneSide ? "phone" : "browser", subValue ? "joined" : "left");
  }

 private:
  bool phoneSide;
};

static void relay(const Frame& f) {
  NimBLECharacteristic* out = (f.dir == TO_PHONE) ? phoneTx : browserTx;
  uint8_t need = (f.dir == TO_PHONE) ? STATUS_PHONE_PRESENT : STATUS_BROWSER_PRESENT;
  if (!(computeStatus() & need)) {
    droppedCount++;
    return;  // nobody listening on that side; sender learns this from STATUS
  }
  for (int attempt = 0; attempt < NOTIFY_RETRIES; attempt++) {
    if (out->notify(f.data, f.len)) {
      relayedCount++;
      return;
    }
    delay(5);  // controller buffers full — let the radio drain
  }
  droppedCount++;
  Serial.println("[relay] frame dropped after retries");
}

void setup() {
  Serial.begin(115200);
  delay(300);
  Serial.printf("\nShlok Key firmware %s\n", FW_VERSION);

  frameQueue = xQueueCreate(QUEUE_DEPTH, sizeof(Frame));

  NimBLEDevice::init(DEVICE_NAME);
  NimBLEDevice::setMTU(247);
  NimBLEDevice::setPower(9);

  server = NimBLEDevice::createServer();
  server->setCallbacks(new ServerCallbacks());
  server->advertiseOnDisconnect(true);

  NimBLEService* svc = server->createService(UUID_SERVICE);

  NimBLECharacteristic* phoneRx = svc->createCharacteristic(UUID_PHONE_RX, NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR, MAX_FRAME);
  phoneTx = svc->createCharacteristic(UUID_PHONE_TX, NIMBLE_PROPERTY::NOTIFY, MAX_FRAME);
  NimBLECharacteristic* browserRx = svc->createCharacteristic(UUID_BROWSER_RX, NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR, MAX_FRAME);
  browserTx = svc->createCharacteristic(UUID_BROWSER_TX, NIMBLE_PROPERTY::NOTIFY, MAX_FRAME);
  statusCh = svc->createCharacteristic(UUID_STATUS, NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY, 1);

  phoneRx->setCallbacks(new RelayCallbacks(TO_BROWSER));
  browserRx->setCallbacks(new RelayCallbacks(TO_PHONE));
  phoneTx->setCallbacks(new PresenceCallbacks(true));
  browserTx->setCallbacks(new PresenceCallbacks(false));

  uint8_t zero = 0;
  statusCh->setValue(&zero, 1);

  svc->start();

  NimBLEAdvertising* adv = NimBLEDevice::getAdvertising();
  adv->addServiceUUID(UUID_SERVICE);  // in the primary packet so iOS can find it while backgrounded
  adv->setName(DEVICE_NAME);
  adv->enableScanResponse(true);
  adv->start();

  Serial.println("[ble] advertising");
}

void loop() {
  Frame f;
  if (xQueueReceive(frameQueue, &f, pdMS_TO_TICKS(50)) == pdTRUE) {
    relay(f);
  }

  if (statusDirty) {
    statusDirty = false;
    uint8_t s = computeStatus();
    if (s != lastStatus) {
      lastStatus = s;
      statusCh->setValue(&s, 1);
      statusCh->notify();
      Serial.printf("[status] phone=%d browser=%d\n", (s & STATUS_PHONE_PRESENT) != 0, (s & STATUS_BROWSER_PRESENT) != 0);
    }
  }

  static uint32_t lastBeat = 0;
  if (millis() - lastBeat > 30000) {
    lastBeat = millis();
    Serial.printf("[beat] peers=%u relayed=%lu dropped=%lu heap=%lu\n", server->getConnectedCount(),
                  (unsigned long)relayedCount, (unsigned long)droppedCount, (unsigned long)ESP.getFreeHeap());
  }
}
