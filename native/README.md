# DKB Monitor Native (`native/`)

Bản viết lại native macOS (Swift) của DKB Monitor — sống **trong cùng repo** với bản Tauri hiện
tại (`src/`, `src-tauri/`), coi như 1 bản nâng cấp tại chỗ (giữ nguyên bundle id/tên app cũ,
không phải sản phẩm tách biệt). 2 phần cùng tồn tại song song cho tới khi cutover xong (Phase
16), lúc đó mới xoá `src/`/`src-tauri/`. Xem kế hoạch đầy đủ tại
[../docs/swift-native-port-plan.md](../docs/swift-native-port-plan.md) — checklist được cập
nhật ở đó khi từng mục hoàn tất.

## Trạng thái hiện tại: Phase 0 (PoC)

Project hiện tại (`project.yml` + `PoC/`) là **1 app scaffold gộp cả 4 PoC** (SMC, Notification,
SSL, Login Item) thành các tab trong 1 app, thay vì 4-6 project Xcode tách rời riêng như plan
gốc mô tả — gộp lại cho gọn, dễ mở 1 lần trong Xcode, không đổi mục tiêu xác nhận.

`MenuBarExtra` + hành vi ẩn/hiện window (PoC thứ 5) đã có sẵn trong `DKBMonitorPoCApp.swift`.
PoC Sparkle (thứ 6) **chưa làm** — cần quyết định trước nơi host appcast (xem Phase 10 trong
plan) nên để sau.

### Cách chạy

```bash
brew install xcodegen   # nếu chưa có
cd native
xcodegen generate       # sinh DKBMonitorPoC.xcodeproj (không commit vào git)
open DKBMonitorPoC.xcodeproj
```

Lưu ý: bundle id của **PoC** (`com.dangkhoabach.dkbmonitor2.poc`) cố tình khác bundle id thật
(`com.dangkhoabach.dkb-monitor`) để không đụng vào Login Item/notification identity của bản
Tauri đang chạy thật trên máy. App target thật ở Phase 1 trở đi mới dùng bundle id sản xuất.

Trong Xcode: chọn Team ký (Signing & Capabilities, cần 1 Apple ID cá nhân — miễn phí) rồi
Cmd+R để chạy.

### Cần bạn tự xác nhận trực tiếp trên máy (tôi không quan sát được UI/permission dialog)

- [ ] **Tab SMC**: bấm "Đọc nhiệt độ" và "Đọc fan RPM" — xem key nào trong danh sách
      `candidateTempKeys` thực sự đọc được giá trị hợp lý trên máy bạn (Apple Silicon), so với
      Activity Monitor/iStat Menus nếu có.
- [ ] **Tab Notification**: "Request permission" → xác nhận dialog hệ thống hiện ra thật (khác
      hạn chế "luôn báo Granted" của bản cũ) → "Send test notification" → ẩn app (Cmd+H) →
      click vào notification hoặc nút "Xem chi tiết" → xác nhận app active lại + dòng
      `lastClickResult` cập nhật.
- [ ] **Tab SSL**: nhập 1 host thật (mặc định `dangkhoabach.vn`), bấm lấy expiry — so sánh với
      kết quả `openssl s_client -connect host:443 | openssl x509 -noout -enddate` để đối chiếu.
- [ ] **Tab Login Item**: Enable → mở System Settings > General > Login Items xác nhận có entry
      "DKBMonitorPoC" đúng tên/icon, không bị duplicate. Bấm Enable thêm vài lần nữa → xác nhận
      **không** tạo thêm entry trùng. Disable → entry biến mất.
- [ ] **Menu bar icon** (waveform icon trên thanh menu bar): click mở menu, "Show main window"
      hoạt động, đóng window chính (nút đỏ) rồi click Dock icon (nếu còn hiện) hoặc menu bar
      "Show main window" lại → xác nhận mở lại được, không bị mất app khỏi cả Dock lẫn menu bar
      cùng lúc.

Báo lại kết quả từng mục (đặc biệt SMC — đây là điểm rủi ro nhất) để cập nhật checklist Phase 0
trong plan và quyết định có tiếp tục Phase 1 hay cần đổi hướng.
