# Unboxer — تقرير فني شامل لمراجعة خبير (Expert Review Brief)

> **الغرض من هذا المستند:** تقديم وصف كامل ودقيق لتطبيق **Unboxer**، ومعماريته، وبيئته التشغيلية،
> والمشكلة التقنية التي وصلنا إليها، بحيث يستطيع خبير خارجي تقييم الوضع باحتراف وإجراء
> بحث/دراسة معمارية عميقة للوصول إلى **أفضل حلّ ومعمارية لهدفنا النهائي: نسخ "كونتينر" تطبيق iOS بالكامل
> (Full App Container Clone) من على الجهاز نفسه.**
>
> التاريخ: 2026-06-13 — الفرع: `claude/app-expert-review-report-qgsk45`

---

## 0) ملخص تنفيذي (Executive Summary)

**Unboxer** تطبيق iOS (SwiftUI) **يعمل على الجهاز نفسه (on-device)**، مُثبّت عبر بيئة Sideloading
(منصة **Nyxian** بدون توقيع Apple رسمي)، ويتواصل مع خدمات النظام في iOS (`lockdownd` وما فوقها)
**عبر نفق VPN محلي (loopback)** بدلاً من كابل USB أو حاسوب مكتبي. الهدف العملي للتطبيق هو **إدارة
التطبيقات المثبّتة** (اكتشاف، تثبيت، حذف، JIT، تركيب DDI، إدارة بروفايلات) و**أخذ نسخة احتياطية من
بيانات التطبيقات**.

الهدف الاستراتيجي الذي نسعى إليه هو **استنساخ كونتينر تطبيق كامل** (الـ Data Container + ما أمكن من
الـ Bundle/الإعدادات) بحيث يمكن لاحقاً إعادته أو نقله. لدينا حالياً مساران للنسخ:

1. **المسار المستقر (مُدمج حالياً):** نسخ عبر **AFC + House Arrest** (`vend_container` / `vend_documents`)
   ثم ضغط الناتج في ملف ZIP. يعمل لكنه **محدود** (يصل فقط لما تسمح به صلاحية House Arrest — غالباً
   مجلد `Documents/` للتطبيقات وليس الكونتينر الكامل).
2. **المسار التجريبي الجديد (محل المشكلة):** نسخ عميق عبر بروتوكول **`mobilebackup2`** (نفس بروتوكول
   النسخ الاحتياطي الكامل للجهاز في Finder/iTunes). هذا المسار **ينهار حالياً** بأخطاء
   `BrokenPipe` (انقطاع القناة) و`check_backup_encryption is not a valid host-initiated request`
   وموت الـ heartbeat فور بدايته.

**جوهر طلبنا للخبير:** ما هي **أفضل معمارية وطريقة وهيكلة** لتحقيق "نسخ كونتينر تطبيق بالكامل" في
بيئتنا الخاصة (on-device + نفق RSD على iOS 17+)؟ هل نُصلح مسار `mobilebackup2`، أم نُعمّق مسار AFC،
أم ننتقل لمعمارية ثالثة؟ التفاصيل والأسئلة الدقيقة في **القسم 9**.

---

## 1) ما هو Unboxer؟ (نظرة عامة على المنتج)

- **النوع:** تطبيق iOS فقط، واجهة **SwiftUI**، هدف نشر `iOS 16.0` (لكن يُبنى بـ Nyxian SDK `26.5`).
- **يُبنى عبر:** `XcodeGen` من ملف `project.yml` (ملف `.xcodeproj` غير مُتتبَّع في git — يُولَّد قبل البناء).
- **التوقيع:** **بدون توقيع Apple** (`CODE_SIGNING_ALLOWED=NO`)؛ يعتمد على entitlements خاصة بـ Nyxian
  (`com.nyxian.pe.*`، فقط `get_task_allowed = true`). أي أن التطبيق يحصل على صلاحيات أوسع من تطبيق
  App Store عادي، لكنه ما يزال **داخل صندوق رمل iOS (sandbox)**.
- **الفكرة الجوهرية:** عادةً تتم إدارة جهاز iOS عبر أدوات مثل `libimobiledevice` من **حاسوب مكتبي**
  عبر USB (الذي يتكلم مع `usbmuxd`). هنا نقوم بنفس الشيء **من داخل تطبيق على الجهاز نفسه**، عبر **نفق
  شبكي محلي** يحاكي وصلة الـ muxer، فيصبح التطبيق "العميل" و`lockdownd` على نفس الجهاز هو "الخادم".

---

## 2) البيئة التشغيلية ونموذج الاتصال (الأهم لفهم المشكلة)

هذه النقطة حاسمة لأي خبير، لأن قيود البيئة هي مصدر معظم الصعوبات:

- **التطبيق يعمل داخل sandbox iOS** كأي تطبيق عادي. لا وصول إلى `/var/run/usbmuxd` (سوكِت يونكس النظامي)،
  ولا صلاحيات root.
- **الوصول لخدمات النظام يتم عبر نفق VPN محلي (loopback / utun)**. في الكود تُستخدم عناوين ثابتة:
  - `10.7.0.1:62078` ← منفذ `lockdownd` التقليدي (للفحص السريع `test_device_connection`).
  - `10.7.0.1:49152` ← نقطة دخول **RemoteServiceDiscovery (RSD)** لأجهزة iOS 17+.
  - يُشار في خطة قديمة إلى `127.0.0.1:27015` كعنوان للـ "localdevVPN".
- **آلية iOS 17+ (RemoteXPC / RSD):** على الإصدارات الحديثة لم يعد بالإمكان الاتصال المباشر بالخدمات؛
  يجب أولاً:
  1. فتح TCP إلى `10.7.0.1:49152`.
  2. تنفيذ **Remote Pairing** باستخدام ملف اقتران (`RpPairingFile`) ومفتاح خاص (`private_key`).
  3. إنشاء **نفق TLS-PSK** (`connect_tls_psk_tunnel_native`) فوق الاتصال.
  4. بناء **Adapter (مكدّس TCP في مستوى المستخدم)** فوق النفق، ثم **RSD Handshake** لاكتشاف الخدمات
     ومنافذها داخل النفق.
  5. كل خدمة (Installation Proxy، AFC، Heartbeat، DebugProxy، MobileBackup2 …) تُفتح كـ
     **اتصال جديد داخل نفس الـ Adapter** عبر `connect_rsd`.
- **ملف الاقتران (Pairing File):** يستورده المستخدم يدوياً (`.plist`) قبل أي عملية. نوعان مدعومان:
  - **RPPairing** (يحوي `private_key`) ← المسار الحديث المعتمد فعلياً (iOS 17+).
  - **Standard Lockdown** (يحوي `UDID`) ← يُكتشف فقط ولا يُستكمل.

> **خلاصة للخبير:** كل الخدمات تتشارك **Adapter/نفق واحد** (`CachedRsdConnection` المخزّن في
> `OnceLock<Mutex<...>>`). هذه نقطة جوهرية في تشخيص انهيار النسخ العميق (راجع القسم 8).

---

## 3) المعمارية بالطبقات (Layered Architecture)

```
┌─────────────────────────────────────────────────────────────────┐
│ UI (SwiftUI)                                                      │
│   UnBoxerApp → ContentView (Tabs: Dashboard, Backups, Settings)   │
├─────────────────────────────────────────────────────────────────┤
│ ViewModels (ObservableObject)                                    │
│   DashboardViewModel · BackupViewModel                           │
├─────────────────────────────────────────────────────────────────┤
│ Services (Swift)                                                 │
│   PairingManager · LockdownEngine · AppDiscoveryEngine           │
│   BackupEngine · MinimuxerBridge(Idevice)                        │
├─────────────────────────────────────────────────────────────────┤
│ FFI Boundary  (@_silgen_name  ⇄  #[no_mangle] extern "C")        │
├─────────────────────────────────────────────────────────────────┤
│ Rust Core  →  RustBridge.xcframework (ios-arm64, staticlib)      │
│   bridge.rs            (واجهة C القديمة عبر rusty_libimobiledevice)│
│   bridge_idevice.rs    (الواجهة الحديثة async عبر idevice crate)  │
│   idevice_support/*    (rsd, apps, install, backup, jit, …)      │
│   post17.rs            (RUNTIME tokio + عمليات iOS 17+)           │
├─────────────────────────────────────────────────────────────────┤
│ مكتبات أصلية مُضمّنة (vendored)                                    │
│   C: libplist · libusbmuxd · libimobiledevice-glue ·             │
│      libimobiledevice                                            │
│   crates: idevice (jkcoxson) · rusty_libimobiledevice · zip      │
│   OpenSSL.xcframework                                             │
├─────────────────────────────────────────────────────────────────┤
│ النقل: نفق VPN محلي (10.7.0.1) → RSD → lockdownd على نفس الجهاز    │
└─────────────────────────────────────────────────────────────────┘
```

**ملاحظة مهمة:** يوجد **مسارا FFI متوازيان**:
- `bridge.rs` (يعتمد `rusty_libimobiledevice` — غلاف فوق مكتبات C عبر usbmuxd) — يبدو إرثياً/احتياطياً.
- `bridge_idevice.rs` + `idevice_support/` (يعتمد crate `idevice` النقي بلغة Rust مع نفق RSD) —
  هو المسار **الفعّال المستخدم** في الميزات الحالية.

هذا الازدواج بحد ذاته نقطة يجب أن يقيّمها الخبير (هل نوحّد على مسار واحد؟).

---

## 4) وصف كل مكوّن/ملف

### 4.1 طبقة التطبيق والواجهة
| الملف | الدور |
|---|---|
| `App/UnBoxerApp.swift` | نقطة الدخول؛ يحقن `PairingManager` كـ `@StateObject`. |
| `Views/ContentView.swift` | الحاوية الرئيسية وتبويبات الواجهة. |
| `Views/DashboardView.swift` | لوحة التحكم: تشغيل المحرك، عرض قائمة التطبيقات، أزرار النسخ. |
| `Views/BackupsView.swift` | متصفّح النسخ الاحتياطية (قوائم، تصفّح ملفات، حذف). |
| `Views/SettingsView.swift` | الإعدادات واستيراد/حذف ملف الاقتران. |
| `Views/TopTabBarView.swift` | شريط التبويبات العلوي. |
| `Models/AppTab.swift` | تعداد التبويبات. |
| `Models/BackupEntry.swift` | نموذج بيانات النسخة (اسم، bundleID، إصدار، تاريخ، حجم، مسار، هل Documents فقط). |

### 4.2 نماذج العرض (ViewModels)
- `DashboardViewModel`: ينسّق `LockdownEngine.executeNativeEngine()` ← `AppDiscoveryEngine.fetchAllApps()`،
  ويدير حالة النسخ (`performBackup`) ورسائل النجاح/الخطأ والـ toast.
- `BackupViewModel`: يحمّل النسخ من مجلد `Documents/Backups`، يفك الضغط عند الطلب (`ensureExtracted`)،
  يتصفّح المحتويات، ويحذف.

### 4.3 الخدمات (Swift)
- `PairingManager`: استيراد/تحليل/حذف `pairing_file.plist` (حد أقصى 1MB)، استخراج `HostID`/`SystemBUID`.
- `LockdownEngine`: يحلّل نوع ملف الاقتران؛ إن كان RPPairing يستدعي `RustIdevice.setRpPairingFile(contents)`
  ثم `testDeviceConnection()` و`fetchUDID()`. (ملاحظة: يحوي تعليقات إرثية عن usbmuxd/UNIX socket.)
- `AppDiscoveryEngine`: يستدعي `RustIdevice.fetchAllApps()` ويحوّل JSON إلى نماذج `AppInfo`.
- `BackupEngine`: المنسّق الفعلي للنسخ — ينشئ مجلد نسخة بطابع زمني، يستدعي
  `RustIdevice.backupApp(bundleId, outputDir)`، يقرأ `zip_path`/`backup_type`، ويكتب `metadata.json`.
  كما يوفّر `ensureExtracted` (يستدعي `RustIdevice.extractZip`).
- `MinimuxerBridge.swift` / `MinimuxerBridgeIdevice.swift`: تعريفات `@_silgen_name` لربط دوال Rust،
  وأغلفة Swift عالية المستوى في الكلاس `RustIdevice` (مع تحويل أخطاء FFI إلى `NSError`).

### 4.4 نواة Rust
| الملف | الدور |
|---|---|
| `lib.rs` | يجمع الوحدات: `bridge`, `bridge_idevice`, `errors`, `idevice_support`, `post17`. |
| `bridge.rs` | واجهة C كاملة عبر `rusty_libimobiledevice` (Device, Lockdown, AFC, InstProxy, Misagent, Mounter, Heartbeat, DebugServer). مسار إرثي. |
| `bridge_idevice.rs` | الواجهة الحديثة: `fetch_all_apps`, `fetch_udid`, `yeet/install/remove`, `debug`, `provisioning`, `mount DDI`, `backup_app`, `extract_zip`. |
| `idevice_support/rsd.rs` | **قلب الاتصال:** إنشاء/تخزين/إعادة استخدام نفق RSD، Remote Pairing، TLS-PSK، الـ Adapter. |
| `idevice_support/apps.rs` | `browse` عبر InstallationProxy لإرجاع تطبيقات المستخدم كـ JSON. |
| `idevice_support/install.rs` | رفع IPA عبر AFC إلى `PublicStaging` ثم التثبيت/الحذف. |
| `idevice_support/backup.rs` | **محرك النسخ الحالي (AFC):** `vend_container`/`vend_documents` → مشي على الشجرة → ZIP. |
| `idevice_support/jit.rs` | تفعيل JIT/التصحيح عبر DVT/DebugProxy (`vAttach`). |
| `idevice_support/mounter.rs` | تركيب صورة المطوّر الشخصية (Personalized DDI). |
| `idevice_support/provision.rs` | تثبيت/حذف/تفريغ بروفايلات provisioning. |
| `idevice_support/device.rs` | فحص الاتصال السريع وجلب UDID. |
| `post17.rs` | يهيّئ `RUNTIME` (tokio multi-thread) وعمليات iOS 17+ (CoreDeviceProxy، DDI mount عبر usbmuxd TCP). |

### 4.5 التبعيات (vendored — لا SPM/CocoaPods)
- C ثابتة: `libplist`, `libusbmuxd`, `libimobiledevice-glue`, `libimobiledevice`.
- `OpenSSL.xcframework` و`RustBridge.xcframework` (كلاهما مُنحّف إلى `ios-arm64` فقط).
- crates أساسية: `idevice` (jkcoxson، rev مثبّت)، `rusty_libimobiledevice` (SideStore)، `plist`, `plist_plus`,
  `tokio`, `zip (deflate)`, `serde_json`.

### 4.6 البناء وCI
- `Scripts/build_rust_bridge.sh`: يبني `aarch64-apple-ios` + `strip -S` ← `RustBridge.xcframework` ثم ينحّف OpenSSL.
- `.github/workflows/`: `build.yml` (يدوي، يبني IPA ويطلق Release) و`build_unboxer_core.yml` (يدوي، يبني نواة Rust ويدفعها).
- **لا توجد اختبارات ولا أدوات lint/format/typecheck.**

---

## 5) القدرات الحالية (Feature Surface)

1. **اكتشاف التطبيقات** (`ApplicationType = User`) مع سماتها الأساسية.
2. **تثبيت/حذف IPA** (رفع عبر AFC إلى `PublicStaging` ثم InstallationProxy).
3. **JIT / Debug** (إطلاق التطبيق معطّل، `vAttach`, رفع حد الذاكرة).
4. **تركيب DDI شخصية** (Personalized Developer Disk Image).
5. **إدارة بروفايلات provisioning** (تثبيت/حذف/تفريغ).
6. **نسخ احتياطي للتطبيق (المسار المستقر — AFC):** نسخ شجرة الكونتينر المتاحة عبر House Arrest إلى ZIP،
   مع `metadata.json`، وفكّ ضغط لاحق وتصفّح.

---

## 6) محرك النسخ الحالي (AFC / House Arrest) وحدوده

التدفق في `idevice_support/backup.rs`:
1. الاتصال بـ `HouseArrestClient` عبر RSD.
2. محاولة `vend_container(bundle_id)` (الكونتينر كاملاً) ← عند الفشل، إعادة الاتصال ثم
   `vend_documents(bundle_id)` (مجلد Documents فقط) كـ fallback. تُسجَّل النتيجة كـ `backup_type = full | documents`.
3. مشي تكراري (DFS) على الشجرة عبر `list_dir` + `get_file_info`، مع **تخطّي صامت** لأخطاء "Permission denied".
4. كتابة كل ملف/مجلد داخل ZIP (deflate)، وحساب `total_bytes`.

### القيود الجوهرية (يجب أن يعرفها الخبير)
- **House Arrest مقيّد بالصلاحيات:** `vend_container` ينجح عملياً فقط لتطبيقات معيّنة (غالباً تطبيقات مطوّر/
  ذات أذونات مناسبة)؛ وإلا يسقط إلى `vend_documents` الذي يعطي **مجلد `Documents/` فقط** — وليس
  الكونتينر الكامل (`Library/`, `tmp/`, `Caches/`, preferences، إلخ).
- **لا يشمل الـ App Bundle** (الملف التنفيذي والموارد) — فقط بيانات الـ Data Container الجزئية.
- **تخطّي الأخطاء صامت:** قد ينتج "نسخة" ناقصة دون إشعار واضح بأن أجزاء حُذفت.
- لذلك **لا يحقق هذا المسار وحده هدف "نسخ كونتينر كامل"** للتطبيقات العامة (App Store apps).

---

## 7) التجربة الجديدة: النسخ العميق عبر `mobilebackup2` (DeepBackup)

لتجاوز قيود AFC، بدأنا تجربة **نسخ عميق** باستخدام بروتوكول **`mobilebackup2`** — نفس بروتوكول النسخ
الاحتياطي الكامل المستخدم في Finder/iTunes، والذي **يصل إلى نطاق `AppDomain-<bundleid>`** الخاص بكل تطبيق
(بيانات أعمق بكثير من House Arrest). هذا المسار **غير مُدمج بعد في شجرة الكود المُتتبَّعة** (هو "التجربة
الجديدة")، والدليل الوحيد المتاح حالياً هو **سجل تتبّع تشغيلي** (`DeepBackupTrace.log`).

### 7.1 السجل الكامل (كما هو)
```
=== deep backup start; work_dir=.../Documents/DeepBackupWork ===
udid=00008103-000D65143C33001E
mobilebackup2: connected
encryption check failed (continuing): unexpected response from device:
        check_backup_encryption is not a valid host-initiated request
heartbeat: connected (proactive keepalive active)
create_dir_all DeepBackupWork/00008103-000D65143C33001E = ok
heartbeat: get_marco error: socket I/O failed: channel closed [BrokenPipe]
backup_from_path error: socket I/O failed: channel closed [BrokenPipe]
RETRY after transport failure: device backup: socket I/O failed: channel closed [BrokenPipe]
mobilebackup2: connected            ← المحاولة الثانية
encryption check failed (continuing): ... check_backup_encryption ...
heartbeat: connected (proactive keepalive active)
create_dir_all ... = ok
heartbeat: get_marco error: socket I/O failed: channel closed [BrokenPipe]
backup_from_path error: socket I/O failed: channel closed [BrokenPipe]
=== deep backup end ===   ← فشل نهائي
```

### 7.2 ملاحظة سياقية مهمة من السجل
مسار العمل: `…/Containers/Data/Application/<A>/Documents/Data/Application/<B>/Documents/DeepBackupWork`
— أي أن العملية تكتب داخل **sandbox التطبيق نفسه**، وهذا متوقع (لا وصول لمسار النظام).

---

## 8) تشخيصنا الأولي للمشكلة (للنقاش مع الخبير)

ثلاثة أعراض متمايزة في السجل:

### العَرَض (أ) — `check_backup_encryption is not a valid host-initiated request`
- في `mobilebackup2` **الجهاز هو من يقود البروتوكول** (يرسل `DLMessageProcessMessage` ورسائل DL أخرى)،
  والمضيف يستجيب. يبدو أننا نحاول **بدء طلب من جهة المضيف (host-initiated)** بأمر فحص تشفير غير معترف به
  في هذا السياق/الإصدار. النتيجة: "نتجاهل ونكمل" — لكن قد يكون هذا أول دليل على **عدم مزامنة حالة
  البروتوكول (handshake/version exchange) منذ البداية**.

### العَرَض (ب) — موت الـ Heartbeat فوراً: `get_marco ... channel closed [BrokenPipe]`
- بروتوكول الـ heartbeat هو **Marco/Polo**: الجهاز يرسل "Marco"، والمضيف يرد "Polo" للإبقاء على
  الجلسة حيّة. هنا فشل أول `get_marco` فوراً بـ `BrokenPipe`، أي أن **قناة الـ heartbeat أُغلقت من
  الطرف الآخر مباشرة بعد فتحها**.

### العَرَض (ج) — `backup_from_path ... channel closed [BrokenPipe]`
- نقل النسخ ينهار بنفس سبب القناة المغلقة.

### فرضياتنا حول السبب الجذري (للتحقّق)
1. **تشارُك نفق/Adapter واحد بين خدمات متعددة متزامنة:** كل الخدمات تمرّ عبر `CachedRsdConnection`
   مفرد (`OnceLock<Mutex>`). فتح **heartbeat + mobilebackup2 معاً** فوق نفس الـ Adapter قد يسبب
   تداخل/تلف في إطارات النفق أو إغلاق متبادل ← `BrokenPipe`. ربما يحتاج النسخ العميق **نفقاً/Adapter
   مستقلاً لكل خدمة طويلة العمر** (أو RSD connection منفصل للـ heartbeat).
2. **عدم إبقاء lockdown session حيّة:** `mobilebackup2` يتطلب heartbeat مستمراً؛ بما أن الـ heartbeat
   يموت فوراً، يُسقِط النظام جلسة النسخ ← انهيار النقل.
3. **مشكلة MTU/MSS في النفق:** يُضبط `adapter.set_mss(mtu - 60)`؛ مكدّس TCP في مستوى المستخدم فوق
   TLS-PSK قد يعاني من تجزئة/إغلاق عند نقل البيانات الكبيرة الخاصة بالنسخ الكامل.
4. **عدم اكتمال handshake البروتوكول** (راجع العَرَض أ): إن لم يتم تبادل الإصدار/القفل بشكل صحيح،
   قد يقطع الجهاز الاتصال فور أول أمر نقل.
5. **قيود البيئة (on-device + sandbox + نفق):** الإبقاء على اتصالات طويلة حيّة في الخلفية على iOS
   صعب (إدارة الطاقة قد تُجمّد/تقطع).

> هذه فرضيات أولية وليست استنتاجات نهائية — نطلب من الخبير التحقّق منها وترجيح السبب الجذري.

---

## 9) ما نطلبه من الخبير بالتحديد (Scope of the Review)

**الهدف النهائي الثابت:** *نسخ كونتينر تطبيق iOS بالكامل (Data Container + أكبر قدر ممكن من الحالة)
من على الجهاز نفسه، عبر نفق RSD، بطريقة موثوقة وقابلة للتكرار.*

نرجو من الخبير تقديم **بحث/دراسة عميقة** تجيب على ما يلي:

1. **اختيار المعمارية الأمثل:** أيّ مسار هو الأصحّ لهدفنا؟
   - (أ) إصلاح/إكمال مسار `mobilebackup2` العميق، أم
   - (ب) تعميق مسار AFC/House Arrest، أم
   - (ج) معمارية ثالثة (مثلاً خدمات CoreDevice/RemoteXPC أحدث، أو مزج المسارين)؟
   مع تبرير هندسي ومقارنة مزايا/عيوب كلٍّ في **بيئتنا تحديداً** (on-device، sandbox، نفق RSD، iOS 17+/18/26).

2. **حدود الواقع التقني:** ما الذي يستطيع `mobilebackup2` فعلاً تسليمه لكل تطبيق؟
   (نطاق `AppDomain-*`، التشفير، الملفات المستثناة بـ `no-backup`/Data Protection، غياب الـ Bundle).
   وهل "الكونتينر الكامل بمعناه الحرفي" قابل للتحقيق دون root/escape؟ وإن لا، فما **أقصى ما يمكن**
   تحقيقه عملياً وما تعريف "النسخة الكاملة المقبولة"؟

3. **تشخيص انهيار `BrokenPipe`:** ترجيح السبب الجذري بين فرضيات القسم 8، وتحديد:
   - هل يجب عزل كل خدمة في نفق/Adapter مستقل؟
   - كيف نُبقي heartbeat (Marco/Polo) حيّاً بشكل صحيح بالتوازي مع النقل؟
   - الترتيب الصحيح وتسلسل handshake لبروتوكول `mobilebackup2` (Version exchange، Hello، Unlock،
     ProcessMessage) في سياق RSD، ومن يبدأ ماذا.

4. **معالجة `check_backup_encryption`:** هل هي مجرد رسالة حميدة، أم عَرَض لخلل في الـ handshake؟ وما
   التعامل الصحيح مع حالة تشفير النسخ (مفعّل/معطّل) في `mobilebackup2`؟

5. **الهيكلة المقترحة للكود:** بنية وحدات/ملفات مقترحة (Rust + Swift) للنسخ العميق: إدارة دورة حياة
   النفق، فصل الخدمات، طبقة heartbeat دائمة، استئناف/إعادة محاولة، تتبّع تقدّم، والتحقق من السلامة.

6. **الموثوقية على iOS:** استراتيجيات الإبقاء على الاتصال حيّاً (background tasks، keep-alive، MSS/MTU)،
   والتعافي من انقطاع النفق.

7. **مسار الاستعادة (Restore):** إن كان الهدف لاحقاً إعادة الكونتينر، ما القيود؟ (`mobilebackup2 restore`
   يتطلب مسح/استعادة على مستوى الجهاز؛ هل هناك مسار أدقّ على مستوى تطبيق واحد؟).

8. **توحيد مساري FFI:** هل نوحّد على `idevice` (المسار الحديث) ونتخلّص من `rusty_libimobiledevice`؟

---

## 10) معطيات بيئية يحتاجها الخبير (Quick Facts)

- الجهاز في السجل: `udid=00008103-000D65143C33001E` (طراز `iPhone` بمعالج A-series حديث حسب بادئة 00008103).
- النقل: نفق RSD على `10.7.0.1:49152`، lockdownd على `:62078`.
- ملف الاقتران: **RPPairing** (يحوي `private_key`) — مسار iOS 17+.
- النسخ يُكتب داخل `Documents/` الخاص بالتطبيق (sandbox).
- crate الاتصال: `idevice` من `jkcoxson` (rev مثبّت في `Cargo.toml`).
- لا توجد حالياً دالة `mobilebackup2` ضمن الكود المُتتبَّع — التجربة الجديدة خارج الشجرة الحالية،
  والمتاح هو سجل التتبّع فقط. (أي أن الخبير يصمّم هذا الجزء فعلياً من الصفر فوق معماريتنا.)

---

## 11) المخرجات المرجوّة من الخبير (Deliverables)

1. **توصية معمارية واضحة** (المسار المختار + المبرّرات).
2. **تشخيص جذري** لانهيار `BrokenPipe`/الـ heartbeat مع خطوات التحقّق.
3. **مخطط تسلسل (sequence)** صحيح لـ `mobilebackup2` فوق RSD مع إدارة heartbeat.
4. **هيكلة كود مقترحة** (وحدات Rust/Swift + مسؤوليات + دورة حياة الاتصال).
5. **تعريف واقعي لـ "النسخة الكاملة"** وحدودها على iOS الحديث.
6. **خطة تنفيذ مرحلية** قابلة للقياس (مع معايير قبول لكل مرحلة).

---

*انتهى التقرير — جاهز للإرسال إلى الخبير. أي ملف مصدري مُشار إليه أعلاه متاح في المستودع للمراجعة المباشرة.*
