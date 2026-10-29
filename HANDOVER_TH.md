# FreshFlow Retail — คู่มือส่งทีม

ปรับปรุง 30 ตุลาคม 2026: Flutter prototype + FastAPI + frozen ML model มีบัญชีและสิทธิ์แยกสาขาทั้ง Real/Demo แล้ว

## เริ่มบน Windows เครื่องใหม่

1. แตก ZIP ทั้งโฟลเดอร์ เก็บโครงสร้าง `app/`, `backend/`, `scripts/`, `artifacts/model/`, `data/` และ `freshflow.db` ไว้ด้วยกัน
2. ติดตั้ง Python 3.11 พร้อม `py` launcher, Chrome และ Flutter SDK ที่มี Dart >= 3.11.1 เพิ่ม `flutter/bin` ใน PATH หรือกำหนด `FLUTTER_SDK` เป็นโฟลเดอร์ SDK
3. รุ่นที่พัฒนาใช้ Dart 3.13.7 ตรวจเครื่องด้วย `py -3.11 --version`, `flutter --version`, `flutter doctor` ไม่ต้องคัดลอก SDK จากเครื่องผู้พัฒนา
4. เปิด PowerShell ที่โฟลเดอร์โปรเจกต์ แล้วติดตั้ง dependencies ครั้งแรก (ต้องใช้อินเทอร์เน็ต):

```powershell
powershell -ExecutionPolicy Bypass -File .\SETUP_TEAM.ps1
```

5. Terminal แรก เปิด Backend:

```powershell
powershell -ExecutionPolicy Bypass -File .\RUN_BACKEND.ps1
```

6. Terminal ที่สอง เปิด Flutter บน Chrome:

```powershell
powershell -ExecutionPolicy Bypass -File .\RUN_FLUTTER.ps1
```

เว็บ: http://127.0.0.1:8080 | Backend: http://127.0.0.1:8000/health

เปิด Terminal ทั้งสองทิ้งไว้ กด R ตัวใหญ่ใน Terminal Flutter เมื่อโค้ดเปลี่ยน ไม่ต้องรันการฝึกโมเดลเพื่อเปิดแอป

## บัญชีและข้อมูล Demo ที่ส่งให้

- ชุดส่งมีสำเนาฐาน Demo พร้อมยอดทดลองเดิม แต่ล้างเฉพาะบัญชี/session/ประวัติความปลอดภัยใน **สำเนาส่งทีมเท่านั้น** ไม่ส่งบัญชีจริงหรือรหัสผ่านของผู้พัฒนา ต้นฉบับที่เครื่องผู้พัฒนาไม่ถูกรีเซ็ต
- ที่ Login เลือก **Demo accounts > Create initial administrator** ตั้งชื่อ อีเมล และรหัสผ่านของทีมอย่างน้อย 12 ตัวอักษร
- หลัง Backend เปิด คัดลอก token ของ Demo โดยไม่แสดงลงหน้าจอ แล้ววางในช่อง Local setup token:

```powershell
Get-Content -LiteralPath .\data\application_demo_2026-10-28.db.setup-token | Set-Clipboard
```

- โหมด Real accounts ตั้ง Administrator แยกกัน ใช้ `data/application.db.setup-token` ไม่มีบัญชีจริงของผู้พัฒนารวมมา
- Administrator สร้าง manager/staff พร้อมกำหนดสาขาได้ Manager สร้าง staff ในขอบเขตตนเอง ลูกค้าสมัครได้เฉพาะบทบาท customer
- Account settings ใช้ดู/แก้ profile เปลี่ยนรหัสผ่าน จัดการพนักงาน และสำรองข้อมูลตามสิทธิ์
- Sign out ยกเลิก session; รีโหลดแอปแล้วต้องล็อกอินใหม่ บัญชีและข้อมูลธุรกิจยังอยู่
- รายละเอียด: [DEMO_ACCOUNTS_TH.md](DEMO_ACCOUNTS_TH.md), [ACCOUNTS_BACKUP_TH.md](ACCOUNTS_BACKUP_TH.md)

## การสาธิตและขอบเขต

1. Manager > AI Forecast: เลือกสาขา วันที่ แผน campaign/holiday และ mock weather แล้ว Run model & recommendations
2. Restock review: ตรวจคำอธิบายยอดเติม การอนุมัติไม่ใช่การรับสินค้าเข้าสต็อก
3. Dynamic Pricing: อนุมัติส่วนลดก่อนเปิด customer deals การขายต่ำกว่าต้นทุนต้องยืนยันเพิ่ม
4. Staff > Inventory > Receive stock: เปิด Daily entry พร้อมสินค้าที่เลือก กรอกจำนวน ล็อต วันหมดอายุ ต้นทุน แล้ว Save to database
5. Staff > Daily entry > Close day: บันทึกยอดขาย/ของเสีย/คงเหลือจริงตามสถานการณ์จำลอง สมการสต็อกต้องสมดุล
6. Customer: ดูดีลที่อนุมัติแล้ว บันทึกข้อเสนอ และแก้ profile ได้ การบันทึกดีลไม่จองสินค้า ไม่รับเงิน และไม่มี QR แคชเชียร์จำลองที่อ้างว่าใช้จริงได้
7. Administrator > Account settings: Back up now และ Test restore ตรวจบนสำเนาชั่วคราว ไม่ทับฐานที่ใช้

Demo อัปเดตตามวันไทยอัตโนมัติขณะ Backend เปิด และตามวันให้เมื่อเปิดใหม่ จึงอาจเห็นยอดเปลี่ยนตามวันหลังได้รับ ZIP แต่ประวัติเดิมไม่ถูกรีเซ็ต โหมดปกติไม่สร้างยอดขายจริงแทนพนักงาน

ข้อมูลฝึกเป็นข้อมูลสังเคราะห์ 4 หมวด Bakery/Produce/Dairy/Meat, 32 สินค้า, 4 สาขา โมเดลหลัก `artifacts/model/model.joblib` ต้องใช้คู่กับ `model_features.joblib` ไม่มีการฝึกใหม่ผ่าน API ข้อมูลอากาศอยู่ในกฎ ไม่ใช่ feature อากาศที่โมเดลเรียนรู้โดยตรง

ผลทดสอบโมเดลสังเคราะห์: MAE 4.4781, RMSE 6.0225, WMAPE 27.8883% ไม่ใช่ accuracy 72% และไม่พิสูจน์ผลลดของเสีย/กำไรในร้านจริง ขอบเขตเป็น Flutter prototype ไม่ต้องมี App Store/POS/ชำระเงินจริง

## อากาศและความลับ

Mock weather ใช้งานได้โดยไม่ตั้ง key หากต้องการ OpenWeather ให้รัน SET_WEATHER_KEY.ps1 ในเครื่องของตนเอง ห้ามส่ง `.env`, `*.setup-token`, ฐานบัญชีจริง หรือ backup ส่วนตัวเข้า Git/แชต

## ตรวจรับของทีม

บน Windows หาก Flutter แจ้ง `Building with plugins requires symlink support` ให้เปิด Settings → System → For developers → Developer Mode แล้วรัน setup ใหม่ (ต้องมีสิทธิ์ตั้งค่าของเครื่องนั้น)

```powershell
.\.venv\Scripts\python.exe -B scripts\team_smoke.py
.\.venv\Scripts\python.exe -B -m unittest backend.test_accounts backend.test_api backend.test_markdown_policy backend.test_weather_config -q
cd app
flutter analyze
flutter test
```

`team_smoke.py` ทดสอบบนฐานสำเนาชั่วคราว ไม่แก้ Demo ที่แนบมา ผลตรวจแพ็กเกจในเครื่องผู้พัฒนาอยู่ `TEAM_VALIDATION.json` ยังไม่ใช่หลักฐานว่าเปิดบนคอมเพื่อนจริงแล้ว ให้เพื่อนกรอก [TEAM_ACCEPTANCE_CHECKLIST.md](TEAM_ACCEPTANCE_CHECKLIST.md) หลังลองเครื่องตนเอง

## สิ่งที่ไม่ต้องใช้เปิดแอป

รายงานเขียนบท งาน ETL/ฝึกซ้ำ ผลทดลองเก่า หน้า UI เก่า และ legacy web ถูกแยกเก็บไว้บน Desktop ของผู้พัฒนา ไม่ต้องติดตั้ง xgboost หรือฝึกโมเดลเพื่อรันแอป `train_demand_model.py` ที่ยังอยู่เป็น dependency สำหรับสร้าง features จึงห้ามลบทิ้งแม้ชื่อขึ้นต้น train

ติดตั้งภายนอกยังต้องเตรียม server/HTTPS และสำรองแยกอุปกรณ์ ชุดนี้เปิดผ่าน loopback บนเครื่องเดียว


## Shared Demo sample (Git)

The repository includes `data/demo_sample.sqlite3`: synthetic trading records from the prepared demonstration, with all users, sessions and security audit rows removed. Run `RUN_BACKEND.ps1` to install it on first launch. Existing local Demo databases are never replaced. Each teammate must create their own Demo administrator using the locally generated setup token. The sample is a fixed snapshot; later calendar updates and trading changes are local to each machine. To install manually before launching Uvicorn, run `py -3 scripts/install_demo_sample.py`.
