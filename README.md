# THIÊN MINH AI AGENT — ĐÁNH GIÁ YÊU CẦU CHÀO GIÁ DỰ ÁN (RFP/RFQ)

Hệ thống AI Agent chạy trên `localhost` giúp **Công ty Thiên Minh** tự động hóa quy trình tiếp nhận, trích xuất, kiểm tra tính đầy đủ, đối chiếu kỹ thuật & năng lực vận hành, tính giá theo chính sách chiết khấu và kiểm soát phê duyệt HITL (Human-in-the-Loop) cho ~20 bộ RFP/RFQ mỗi tháng.

---

## 1. Cách khởi chạy trên localhost (macOS — không cần cài thêm Python/Node)

```bash
cd "/Users/nguyenphuongyennhi/GIUA MON NHOM 5 AGENT"
chmod +x start.sh
./start.sh
```

Hoặc chạy trực tiếp bằng Ruby tích hợp sẵn của macOS:

```bash
ruby --disable-gems server.rb
```

Sau đó mở trình duyệt tại: **http://127.0.0.1:8787** (hoặc **http://localhost:8787**).

---

## 2. Kiến trúc & Quy trình AI Agent (khớp 100% sơ đồ vận hành)

1. **Tiếp nhận yêu cầu chào giá (RFP/RFQ)**: Hỗ trợ văn bản đa đoạn, email rời rạc, ghi chú khảo sát.
2. **[AI AGENT] Trích xuất & Phân rã yêu cầu (`lib/rfp_extractor.rb`)**: Bóc tách hạng mục, số lượng, thông số kỹ thuật bắt buộc, thời hạn (deadline), ngân sách, điều kiện bắt buộc (CO/CQ, SLA, chứng chỉ, điều khoản phạt...).
3. **Cổng kiểm tra: Có đủ thông tin?**:
   - **Không**: Chặn lập báo giá, liệt kê phần thiếu sót & tự động soạn email cho **Kinh doanh liên hệ KH yêu cầu bổ sung**. Sau khi nhập phản hồi KH, quy trình tự động chạy lại từ bước đầu.
   - **Có**: Chuyển bước đối chiếu kỹ thuật & vận hành.
4. **[AI AGENT] Đối chiếu giải pháp, năng lực & lịch triển khai (`lib/feasibility_matcher.rb`)**:
   - Kiểm tra chéo với `data/catalog.json` và **tự động loại bỏ các gói giá thấp không đủ chức năng bắt buộc** (chống bẫy giá rẻ).
   - Gắn cờ hạng mục **ngoài danh mục chuẩn**.
   - Đối chiếu `data/capacity_schedule.json` theo tuần để phát hiện quá tải hoặc không kịp lead-time.
5. **[AI AGENT] Tính toán giá đề xuất & áp dụng chính sách chiết khấu (`lib/pricing_engine.rb`)**:
   - Tính BOM thiết bị, dịch vụ triển khai, bảo trì, VAT, biên lợi nhuận gộp và so khớp ngân sách KH.
6. **Cổng kiểm tra: Có vượt thẩm quyền / Chiết khấu đặc biệt / Thiết bị ngoài danh mục?**:
   - **Có**: Chuyển nhánh HITL **Trưởng phòng duyệt / Ban Giám đốc phê duyệt**.
   - **Không**: Chuyển thẳng bước hợp nhất tài liệu.
7. **Hợp nhất tài liệu & Thẩm định cuối (`lib/proposal_builder.rb`)**:
   - Tạo **Hồ sơ đề xuất**, **Ma trận đáp ứng (Compliance Matrix)** và **Dự thảo bản chào giá**.
   - **HITL: Thẩm định & Kiểm tra ranh giới dữ liệu (Kinh doanh + Kỹ thuật + Vận hành duyệt cuối)**.
   - Hỗ trợ nhánh **Cần chỉnh sửa** (lặp lại quy trình) và **Đạt -> Xuất bản chào giá & Gửi khách hàng** (xem bản in / tải file `.md`).

---

## 3. Cơ chế AI Hybrid (`lib/llm_client.rb`)

- **Mặc định (Offline NLP + Rule Engine)**: Hoạt động ngay lập tức không cần API Key.
- **Kết nối LLM thật (Gemini / OpenAI)**: Vào tab **⚙️ Cấu hình AI (Hybrid)** trên giao diện web để nhập API Key (`gemini-2.5-flash` hoặc `gpt-4o-mini`). Khi bật LLM, hệ thống vẫn áp dụng lớp kiểm tra ranh giới dữ liệu nội bộ để đảm bảo không bịa giá hay sai SKU.

---

## 4. 5 Kịch bản mẫu đã nạp sẵn (`data/sample_rfps.json`)

| Mã hồ sơ | Khách hàng | Kịch bản kiểm chứng |
|---|---|---|
| `RFP-2026-1101` | Tập đoàn Logistics Đông Nam | Đủ thông tin, khớp kỹ thuật & lịch tuần, trong thẩm quyền -> Sẵn sàng duyệt cuối |
| `RFP-2026-1102` | Bệnh viện Đa khoa Tâm An | Thiếu số lượng, thông số & deadline -> Dừng ở nhánh **Kinh doanh hỏi thêm KH** |
| `RFP-2026-1103` | Công ty CP Fintech An Phát | Chặn bẫy gói giá thấp + Cảnh báo xung đột lịch 10 ngày vào tuần 95% tải + Vượt ngân sách |
| `RFP-2026-1104` | Chuỗi Bán lẻ SunMart | Thiết bị ngoài danh mục (Switch IP67) + Chiết khấu 14% + Phạt tiến độ -> Duyệt Ban Giám đốc |
| `RFP-2026-1105` | Công ty Sản xuất Hòa Bình | Hồ sơ đa đoạn phức tạp (5 đoạn) -> Bóc tách đủ điều kiện CO/CQ, chứng chỉ CCNP/NSE4, SLA 24x7 |
