#!/usr/bin/env python3
"""Summarize recorded measurements; never estimates unmeasured memory values."""
import json
import pathlib
import sys

baseline = json.loads(pathlib.Path(sys.argv[1]).read_text())
final = json.loads(pathlib.Path(sys.argv[2]).read_text())
assert baseline[-1]['phase'] == final[-1]['phase'] == 'after_clear_all'
assert not any(row.get('interruptedBySleep', False) for row in baseline + final), 'Sleep interrupted benchmark'
assert any(row['phase'] == 'idle_10_minutes' for row in baseline)
labels = {
    'idle_initial': 'Idle sau khởi động',
    'idle_10_minutes': 'Idle sau 10 phút',
    'idle_5_seconds': 'Idle đối chiếu sau 5 giây',
    'after_1000_text': 'Sau 1.000 text',
    'after_100_images_512px': 'Sau 100 PNG 512 × 512',
    'popup_images': 'Popup có thumbnail ảnh',
    'after_20_popup_cycles': 'Sau 20 lần mở/đóng',
    'after_100_popup_cycles': 'Sau 100 lần mở/đóng',
    'after_clear_all': 'Sau xóa toàn bộ lịch sử',
}
lines = ['# Benchmark SwiftClip — 02/11/2026', '',
         'Máy arm64, macOS 27.2 (26B123), Xcode 27.2 (27B52). Release universal, chạy native arm64, không gắn Instruments vào các lần đo dưới đây.', '',
         'Số đo dùng Mach TASK_VM_INFO: physical footprint và resident size (RSS) là hai chỉ số khác nhau. MiB = 1.048.576 bytes. Không thay RSS bằng physical footprint hoặc ngược lại khi so với mục tiêu RAM.', '',
         'Fixture: database/pasteboard tạm riêng; Unlimited; 1.000 text nhiều dòng; 100 PNG 512 × 512 ngẫu nhiên; trang 60 mục; popup mở/đóng 100 lần ở bài dài, 20 lần ở bài ngắn; sau đó Clear All. Đây là tải tổng hợp, không đại diện mọi kích thước ảnh hoặc ứng dụng nguồn.', '']
for title, data in [('Baseline Release, 10 phút idle độc lập', baseline), ('Executable Release cuối, bài đo đối chiếu ngắn', final)]:
    lines += ['## ' + title, '', '| Trạng thái | Physical footprint (MiB) | RSS (MiB) |', '|---|---:|---:|']
    for row in data:
        lines.append(f"| {labels.get(row['phase'],row['phase'])} | {row['physicalFootprintMiB']:.2f} | {row['residentMiB']:.2f} |")
    initial = data[0]
    idle = next(row for row in data if row["phase"] in ["idle_10_minutes","idle_5_seconds"])
    percent = (idle['cpuSeconds'] - initial['cpuSeconds']) / (idle['seconds'] - initial['seconds']) * 100
    lines += ['', f'CPU trong khoảng idle: **{percent:.3f}% của một core**, tính từ delta CPU user+system / thời gian monotonic của chính tiến trình. Đây không phải % toàn bộ máy. Không dùng CPU trung bình của cả bài ingest làm CPU idle.', '']
lines += [
    '## Diễn giải và giới hạn', '',
    '- Lần 10 phút dùng bản sao Release có bundle/executable riêng để tránh LaunchServices/UI automation chọn nhầm. Bản sao dùng cùng executable Release phát hành; chỉ đổi bundle ID/tên executable, ký lại ad-hoc, và icon đồng hồ cát trong chế độ diagnostic. Bài ngắn đối chiếu trực tiếp executable phát hành. Kết quả vẫn chỉ áp dụng cho các bản đã đo, không bảo đảm mọi cấu hình.',
    '- Bộ nhớ sau mở popup không nhất thiết quay về mức cold start: AppKit/SwiftUI/ImageIO có cache theo tiến trình. So sánh mức popup đầu với mức sau 20 chu kỳ; số đo ngắn không đủ chứng minh ổn định qua nhiều ngày.',
    '- Mục tiêu idle 10–20 MB / popup text <30 MB / có ảnh <40 MB là mục tiêu thiết kế. Không tuyên bố mọi mục tiêu đạt; bảng trên báo số đo thật theo MiB. Chưa có phép đo riêng cho popup chỉ chứa text.',
    '- Apple leaks trên bản profiling: **0 leaks, 0 leaked bytes** trong bài thử ngắn. Xem LEAKS_REPORT.md. Allocations đã ghi được trace; các số đo có instrumentation không dùng làm baseline. Phiên Instruments Leaks kẹt ở bước lưu nên không được tính là hoàn tất.',
    '- Lần đo đầu bị xen kẽ các thử attach Instruments/UI và các lần đo riêng bị đóng hoặc sleep trước khi đủ thời gian; không dùng chúng làm baseline. Lần đo nhiễu ghi nhận khoảng 50,5 MiB sau mốc 10 phút; không dùng kết quả này làm idle baseline. Dữ liệu thô được dọn theo yêu cầu sau khi ghi báo cáo.',
    '- Xcode Memory Graph, Activity Monitor review trực tiếp, logout/login, quyền Accessibility và thử trên macOS 13/Intel vẫn cần nghiệm thu thủ công. Xem MANUAL_ACCEPTANCE.md.', '',
    'Dữ liệu thô: benchmark-baseline.json, benchmark-final-release.json; log tests: test-run.log. Chạy lại: `bash Scripts/benchmark.sh`; tạo báo cáo từ hai JSON: `python3 Scripts/benchmark_report.py BASELINE.json FINAL.json`.',
]
pathlib.Path('Docs/BENCHMARK.md').write_text('\n'.join(lines) + '\n')
