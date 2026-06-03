# Unboxer: Lockdownd Architecture & Execution Plan

أهلاً بك، هذه هي الخطة المعمارية التفصيلية (Step-by-Step Execution Plan) لإعادة بناء محرك الاتصال بـ `lockdownd` من الصفر باستخدام لغتي **Swift** و **Pure C** فقط، وبما يتوافق مع بيئة emexDE (بدون أي مترجمات Rust).

## User Review Required

> [!IMPORTANT]
> يرجى مراجعة الخطة والتأكد من توافق أسماء الملفات المقترحة وهيكليتها مع معايير مشروعكم الحالية في `Unboxer`. بمجرد الموافقة، سنبدأ بكتابة الأكواد المعمارية خطوة بخطوة.

---

## Proposed Changes (Phases)

### Phase 1: Networking & Sockets (طبقة الشبكة والاتصال)
سنستخدم `Network.framework` في Swift كلغة أساسية للاتصال لكونها أقوى في إدارة دورة حياة الشبكة في الخلفية وتجنب الانهيارات، مع توفير طبقة C (POSIX) كدعم منخفض المستوى.

#### [NEW] `Services/Networking/UBNetworkClient.swift` (Swift)
- **الوظيفة:** بناء الـ TCP Client الحديث باستخدام `NWConnection` و `NWParameters.tcp`.
- **التفاصيل:** سيتصل بـ `127.0.0.1:27015` (IP الخاص بـ localdevVPN). إطار عمل أبل للشبكات يتعامل تلقائياً مع الـ `SIGPIPE`، لكننا سنضمن استقراراً إضافياً.

#### [NEW] `Core/Sockets/UBSocketHelpers.h` & `.c` (Pure C)
- **الوظيفة:** دوال C نقية للتعامل مع خيارات الـ POSIX Sockets (في حال الحاجة إلى Fallback أو بناء Listener داخلي).
- **التفاصيل:** تطبيق `setsockopt` مع `SO_REUSEADDR` (لتجنب تعليق البورت `TIME_WAIT` بعد انهيار الـ VPN) و `SO_NOSIGPIPE` (لمنع انهيار التطبيق عند الكتابة على اتصال مقطوع).

---

### Phase 2: usbmuxd Emulation (محاكاة بروتوكول usbmuxd)
نحتاج إلى محاكاة خدمة usbmuxd بدقة متناهية وإرسال الـ Packets وفقاً لمعايير أبل المعكوسة (Little-Endian).

#### [NEW] `Core/Protocol/usbmuxd_packet.h` (Pure C)
- **الوظيفة:** تعريف هيكل البيانات (Data Struct) للرأس (16-byte Header).
- **التفاصيل:**
  ```c
  #pragma pack(push, 1)
  typedef struct {
      uint32_t length;
      uint32_t version;
      uint32_t request;
      uint32_t tag;
  } usbmuxd_header_t;
  #pragma pack(pop)
  ```

#### [NEW] `Services/Protocol/UBRawPacket.swift` (Swift)
- **الوظيفة:** تغليف الـ C Struct وتحويله إلى/من `Data` في Swift.
- **التفاصيل:** مسؤول عن تحويل الـ Integers إلى `Little-Endian`. سيقوم أيضاً بتغليف قراءة الـ Payload (XML Plist) بشكل آمن لمنع الـ Memory Leaks الناجمة عن التجزئة (Packet Fragmentation) عبر قراءة الـ 16-byte أولاً، ثم حجب الـ Thread حتى يكتمل وصول الـ Payload بناءً على قيمة `length`.

#### [NEW] `Services/Protocol/UBPlistEncoder.swift` (Swift)
- **الوظيفة:** توليد الـ XML Plists وتشفير مفاتيح `HostID` و `SystemBUID` قبل دمجها مع الـ Header وإرسالها عبر الـ Socket.

---

### Phase 3: Lockdownd Handshake & TLS (Native Apple Approach)
بمجرد إرسال أمر `StartSession` عبر `usbmuxd` واستلام `EnableSessionSSL: true` من `lockdownd`، سنقوم بترقية الاتصال إلى mTLS محلياً.

#### [NEW] `Services/Lockdownd/UBPairingManager.swift` (Swift)
- **الوظيفة:** قراءة وتحليل ملف الـ Pairing (`.plist`) المرفق في المشروع (باستخدام `PropertyListSerialization`).
- **التفاصيل:** استخراج `HostCertificate` و `HostPrivateKey` كـ `Data` من الـ Plist.

#### [NEW] `Services/Lockdownd/UBIdentityBuilder.swift` (Swift)
- **الوظيفة:** بناء `SecIdentity` صالح محلياً.
- **التفاصيل:** استخدام `Security.framework` (`SecCertificateCreateWithData` و `SecKeyCreateWithData` أو PKCS#12) لإنشاء Identity يمكن تمريره لخيارات الـ Network.framework.

#### [NEW] `Services/Lockdownd/UBLockdowndSession.swift` (Swift)
- **الوظيفة:** إدارة الترقية لـ TLS.
- **التفاصيل:** حقن الـ `SecIdentity` في خيارات `NWParameters.tls` باستخدام `sec_protocol_options_set_local_identity`، ثم استدعاء الترقية لبروتوكول الـ TLS محلياً.

---

### Phase 4: Stability & Heartbeat (نبض الحياة والاستقرار)
نظرًا لأن iOS يقتل الاتصالات الخاملة في الخلفية، نحتاج لميكانيكية دائمة النبض.

#### [NEW] `Services/Networking/UBVPNMonitor.swift` (Swift)
- **الوظيفة:** مراقبة حالة الواجهة الوهمية (loopback/utun) عبر واجهات الـ C `getifaddrs()`.
- **التفاصيل:** بمجرد اكتشاف انقطاع في واجهة localdevVPN، يقوم بإسقاط الـ Socket فوراً من الذاكرة وإعادة محاولة الربط السريع (Fast Re-bind) لتجاوز مشاكل الانتظار.

#### [NEW] `Services/Lockdownd/UBHeartbeatDaemon.swift` (Swift)
- **الوظيفة:** إرسال نبضات حياة (Keep-Alive) مستمرة لخدمة `lockdownd`.
- **التفاصيل:** سيعمل في `Task` منفصل (Background Thread) ويتبادل رسائل Ping-Pong مع الجهاز لتجنب إغلاق الجلسة بواسطة نظام إدارة الطاقة في iOS.

---

## Verification Plan
1. **اختبار الطبقة السفلية:** مراقبة Logs الـ TCP Client للتأكد من نجاح الاتصال بـ `127.0.0.1:27015` فور تشغيل الـ VPN الوهمي.
2. **اختبار البروتوكول:** التأكد من إرسال أول Packet `Listen` واستلام الرد دون حدوث Buffer Overflow أو تسريب ذاكرة.
3. **اختبار التشفير:** إرسال الـ Pairing Plist ومراقبة نجاح دالة `lockdownd_client_new_with_handshake()`.
4. **اختبار الاستقرار:** إطفاء وتشغيل الـ VPN الوهمي بشكل مفاجئ، ومراقبة قدرة `UBVPNMonitor` على التعافي في أقل من ثانية.
