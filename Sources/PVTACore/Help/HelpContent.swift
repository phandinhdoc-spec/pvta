import Foundation

public struct HelpChapter: Codable, Sendable, Equatable {
    public var id: String
    public var group: String
    public var title: String
    public var body: String
}

/// Sách hướng dẫn của PVTA (bản mới, không có phần add-in Office). Mỗi nhiệm vụ làm xong thì bổ sung chương tương ứng.
enum HelpContent {
    static let all: [HelpChapter] = [
        HelpChapter(id: "bat-dau", group: "Bắt đầu", title: "Bắt đầu với PVTA", body: """
            PVTA lưu dữ liệu của thầy cô trong thư mục `~/Library/Application Support/PVTA` (hội thoại, dự án, cài đặt, nhật ký). Khóa API và mã đăng nhập chỉ nằm trong Keychain của macOS, không ghi vào tệp cấu hình hay nhật ký.
            Chỉ một tiến trình giữ dữ liệu; các cửa sổ và dòng lệnh khác tự nối vào tiến trình đó, nên mở nhiều cửa sổ không gây xung đột.
            Xuất toàn bộ dữ liệu ra một tệp JSON để sao lưu hoặc chuyển máy bằng chức năng xuất/nhập; nhập lại nhiều lần không tạo bản trùng. Có thể sao lưu cả cơ sở dữ liệu thành một tệp riêng.
            Khi gặp lỗi, mở nhật ký hoạt động và xuất báo cáo: báo cáo đã che khóa và không chứa nội dung hội thoại.
            """),
        HelpChapter(id: "mo-hinh-ai", group: "Mô hình AI", title: "Chọn mô hình AI và đăng nhập", body: """
            PVTA dùng được hai loại nguồn: các nhà cung cấp API (Anthropic, OpenAI, Google Gemini, Command Code, Ollama và máy chủ tương thích như LM Studio) và các công cụ dòng lệnh đã đăng nhập (Claude, Codex, Antigravity, OpenCode). Mọi skill, chế độ viết và quy tắc dùng chung cho mọi nguồn.
            Chọn “Tự động” để PVTA chọn model theo loại việc và nguồn đang dùng được trên máy. Khóa API nhập từ cửa sổ cài đặt và lưu trong Keychain. Với công cụ dòng lệnh, PVTA hướng dẫn cài và đăng nhập từng bước; OpenCode có model miễn phí.
            Khi một nguồn đã dùng từ 90% hạn mức, PVTA cảnh báo và đề nghị chuyển sang nguồn khác; nếu nhà cung cấp từ chối vì hết hạn mức, PVTA dừng, lưu ngữ cảnh và chờ thầy cô chọn nguồn thay thế rồi làm tiếp. Cờ “việc gấp” chỉ tăng số bước chạy song song, không đổi mức quyền.
            """),
        HelpChapter(id: "hoi-thoai", group: "Hội thoại", title: "Hội thoại, hàng đợi và ngữ cảnh dài", body: """
            Mỗi lượt, PVTA gửi lời của thầy cô cho model, chạy các công cụ model gọi rồi gửi kết quả lại, tối đa 8 vòng; chạm giới hạn thì báo rõ. Nút Dừng dừng cả lượt, giữ phần đã nhận.
            Khi hội thoại đang bận, xếp lời lệnh mới vào hàng đợi: “xếp hàng” chạy sau lượt hiện tại, “chen vào” chạy ở ranh giới giữa hai lần gọi model. Có thể dời, sửa, xóa lời lệnh đang chờ.
            Hội thoại dài quá khoảng 48.000 ký tự thì phần cũ được tóm tắt, tin mới nhất giữ nguyên; nếu không tóm tắt được, PVTA báo rõ. Bản nháp ô soạn được lưu theo từng hội thoại. Mỗi hội thoại có thể chọn model riêng.
            """),
        HelpChapter(id: "dinh-kem", group: "Hội thoại", title: "Tệp, ảnh, chụp màn hình và chọn nguồn", body: """
            Model chỉ đọc được những gì thầy cô đính kèm vào hội thoại. Gõ đường dẫn trong câu hỏi không cấp quyền đọc. PVTA đọc chữ từ văn bản, Markdown, CSV, Word, Excel, PowerPoint và PDF; PDF quét ảnh chưa có chữ được báo rõ thay vì bỏ qua.
            Ảnh (PNG, JPEG, GIF, WebP, mỗi ảnh tối đa 5 MB) được gửi kèm lượt kế tiếp. Chụp màn hình cần cấp quyền Ghi màn hình cho PVTA trong Cài đặt hệ thống, Quyền riêng tư và Bảo mật; chưa có quyền thì PVTA hướng dẫn thay vì chụp ra ảnh trống.
            Đính kèm một thư mục chỉ để chọn tệp: gõ `$` để tìm tệp và `$$` để tìm thư mục theo tên, có dấu hoặc không dấu; nội dung thư mục không tự gửi cho model.
            """),
        HelpChapter(id: "quyen", group: "An toàn", title: "Ba mức quyền và duyệt thao tác", body: """
            PVTA có ba mức quyền: Chỉ đọc (từ chối mọi ghi, chạy lệnh, truy cập mạng), Hỏi duyệt (mặc định: mọi thao tác ngoài đọc chờ thầy cô duyệt) và Tự sửa (tự ghi, sửa, chuyển vào Thùng rác trong thư mục đã cấp quyền, nhưng chạy mã, truy cập mạng và thao tác nguy hiểm vẫn phải duyệt). Chuyển sang Tự sửa phải xác nhận vì đây không phải môi trường cô lập.
            Mức quyền không bao giờ tự tăng: model, công cụ hay cờ việc gấp đều không đổi được. Thao tác chờ duyệt hiện đủ nội dung xem trước; không trả lời trong 300 giây thì coi như từ chối.
            Công cụ tệp chỉ làm việc trong thư mục thầy cô đã cấp. Các vùng hệ thống, thư mục cá nhân gốc, `~/.ssh` và dữ liệu PVTA không cấp được. Thao tác nguy hiểm (xóa cả thư mục, xóa hơn 5 mục, ghi hơn 20 tệp) luôn cần bấm “Vẫn làm”.
            """),
        HelpChapter(id: "cong-cu-tep", group: "An toàn", title: "Công cụ tệp, phiên sửa và hoàn tác", body: """
            Model có thể liệt kê, đọc, tìm (không phân biệt dấu), ghi, sửa một phần, di chuyển và chuyển vào Thùng rác trong thư mục đã cấp quyền. Mọi thao tác ghi vào hàng đợi duyệt kèm bản xem trước. PVTA không ghi đè tệp có sẵn khi chưa được cho phép rõ và không xóa hẳn tệp, chỉ chuyển vào Thùng rác.
            Mỗi thay đổi được ghi lại để hoàn tác; hoàn tác chỉ chạy khi tệp vẫn đúng như PVTA để lại. Phiên sửa tệp giữ bản nháp riêng: tệp gốc chỉ đổi khi thầy cô lưu, và nếu tệp gốc đã bị sửa bên ngoài thì PVTA báo xung đột thay vì ghi đè.
            """),
        HelpChapter(id: "chay-ma", group: "An toàn", title: "Chạy mã có duyệt", body: """
            PVTA chạy được Python 3, Node.js và bash có sẵn trên máy; PVTA không tự cài trình thông dịch. Trước mỗi lần chạy, mã được quét theo mẫu và phản biện bằng AI, rồi hiện thẻ Duyệt mã. Mỗi lần chạy xin duyệt riêng, kể cả ở mức Tự sửa. Cảnh báo mức Cao cần bấm “Vẫn chạy”.
            Mỗi lượt chạy có thư mục riêng `chay-ma-<mã>` trong thư mục kết quả; tệp đính kèm được chép vào, bản gốc không bị sửa. Mã không mang theo khóa API. Hết giờ (mặc định 30 phút) thì PVTA dừng cả cây tiến trình. Mã chạy với quyền tài khoản của thầy cô, không có cô lập.
            """),
        HelpChapter(id: "che-do-viet", group: "Soạn thảo", title: "Chế độ viết, quy tắc #khóa và lời nhắc mẫu @khóa", body: """
            Có sẵn 7 chế độ viết: Sư phạm (mặc định), Chính xác, Học thuật, Kế toán, Sáng tạo, Hành chính, Ngắn gọn. Thầy cô tạo chế độ riêng; mỗi lần sửa hoặc xóa đều được lưu để xem trước và khôi phục.
            Quy tắc là các dòng thầy cô muốn PVTA luôn theo. Quy tắc “luôn áp dụng” nạp mọi lượt; quy tắc khác gọi bằng `#khóa` khi gõ yêu cầu. Quy tắc có ba phạm vi: cá nhân, dự án, hội thoại; cùng khóa thì phạm vi hẹp hơn thắng.
            Thư viện có 24 lời nhắc mẫu cho giáo viên (soạn bài, kiểm tra đánh giá, điểm số, trình chiếu, văn bản hành chính, học sinh phụ huynh). Gõ `@khóa` để chèn; ô trống `[mô tả]` chưa điền sẽ được PVTA hỏi lại, không tự bịa. “Tối ưu lời nhắc” viết lại ý thô thành lời nhắc rõ, chỗ thiếu thông tin để ô trống.
            """),
        HelpChapter(id: "word", group: "Tài liệu", title: "Tệp Word (.docx)", body: """
            PVTA đọc tệp Word thành các khối có số thứ tự, tạo tài liệu mới (tiêu đề, đoạn, danh sách, bảng, ảnh, công thức, ngắt trang) và sửa tệp có sẵn. Công thức Toán và Hóa viết trong dấu đô la, ví dụ `$x^2+1$` hay `\\ce{2H2 + O2 -> 2H2O}`, được đổi thành phương trình chuẩn của Word.
            Mọi chỉnh sửa luôn ra một bản sao mới (“tên (đã sửa).docx”), không ghi đè tệp gốc, và cần thầy cô duyệt. Phần PVTA không sửa giữ nguyên định dạng của tệp gốc.
            """),
        HelpChapter(id: "excel", group: "Tài liệu", title: "Tệp Excel (.xlsx)", body: """
            PVTA đọc bảng tính (giá trị kèm công thức), tạo sổ tính mới và sửa tệp có sẵn: ghi ô, công thức, tô màu, định dạng số, bộ lọc, đóng băng hàng, gộp ô, độ rộng cột, thêm trang tính và biểu đồ cột, đường, tròn. Điểm và tiền cần là số thật.
            Công thức được PVTA tính lại và báo lỗi (như chia cho 0); Excel cũng tự tính lại khi mở tệp. Hàm ngoài tập PVTA hỗ trợ vẫn được ghi, nhưng PVTA báo là chưa tính được. Sửa luôn ra bản sao mới và cần duyệt.
            """),
        HelpChapter(id: "powerpoint", group: "Tài liệu", title: "Tệp PowerPoint (.pptx)", body: """
            PVTA đọc từng slide và mã hình, tạo bài trình chiếu 16:9 theo bố cục có sẵn (tiêu đề, nội dung, hai cột) với màu và phông theo môn học, và sửa chữ, phông, màu hoặc vị trí hình trên một bản sao. Tệp gốc không bị ghi đè; mọi thay đổi cần thầy cô duyệt.
            """),
        HelpChapter(id: "pdf", group: "Tài liệu", title: "Tệp PDF", body: """
            PVTA đọc chữ PDF theo trang hoặc theo một vùng, gộp nhiều PDF, tách trang thành PDF mới. PDF quét ảnh chưa có lớp chữ được báo rõ là cần OCR. Việc lưu PDF luôn tạo tệp mới và cần duyệt; ghi từng đoạn dữ liệu có thể hủy giữa chừng mà không để lại tệp hỏng. PVTA tìm phông có đủ dấu tiếng Việt để chèn chữ.
            """),
        HelpChapter(id: "typst", group: "Tài liệu", title: "Làm đẹp tài liệu bằng Typst", body: """
            Từ Markdown hoặc văn bản, PVTA xuất một tệp ZIP gồm `document.pdf`, `document.typ`, ảnh xem trước và hướng dẫn. Mẫu `.typ` hoặc `.md` thầy cô đính kèm được đọc để rút quy tắc lề, phân cấp chữ, khoảng cách, bảng, màu nhấn. Mã `.typ` lỗi thì không tạo tệp; tên trùng không bị ghi đè; luôn hỏi duyệt trước khi biên dịch và ghi.
            """),
        HelpChapter(id: "skill", group: "Kỹ năng", title: "Skill: nạp, gọi bằng /tên và quản lý", body: """
            Skill là thư mục có tệp SKILL.md, dùng chung cho mọi model. PVTA nạp phần khai báo trước: skill “luôn nạp” đưa nội dung vào ngữ cảnh, skill “khi cần” chỉ liệt kê tên và mô tả để model đọc khi cần, skill “thủ công” chỉ nạp khi thầy cô gõ `/tên`.
            Thầy cô bật/tắt, tạo, sửa (có sao lưu và khôi phục), xóa skill. Skill mới phải có mô tả, và mọi dòng ở mục Quy định phải ghi nguồn “(Nguồn: …)”. Skill cài từ thư mục hoặc GitHub luôn bắt đầu ở chế độ thủ công; nội dung chứa lệnh shell, khóa bí mật hay câu bảo bỏ qua chỉ dẫn bị từ chối kèm lý do.
            """),
        HelpChapter(id: "nhom", group: "Kỹ năng", title: "Nhóm theo vai trò và hồ sơ học kỳ/tổ", body: """
            Thầy cô tick chọn nhóm theo vai trò (giáo viên, tổ trưởng, hiệu phó, hiệu trưởng, văn thư, kế toán…), chuyên môn và công cụ. PVTA chỉ nạp skill của nhóm đã chọn (và skill riêng của thầy cô); AI không tự tìm skill ngoài nhóm. Chưa chọn nhóm nào thì skill gắn nhóm chưa được nạp; có thể bấm một gói chọn nhanh.
            Hồ sơ học kỳ/tổ lưu tập nhóm đang chọn để áp dụng lại; áp dụng qua bước xem trước và xác nhận, hoàn tác được. Gói nhóm `.pvtagroup` xem trước, cài (không tự bật) và xuất để chia sẻ với đồng nghiệp.
            """),
        HelpChapter(id: "van-ban-moi", group: "Kỹ năng", title: "Văn bản mới, tóm tắt và kiểm tra căn cứ", body: """
            Với nhóm đã chọn, PVTA tìm văn bản mới trong các nguồn tin thầy cô thêm (trang của cơ quan nhà nước .gov.vn hoặc giáo dục .edu.vn) hoặc nguồn tin do gói nhóm khai báo. Văn bản được tải về kho trên máy; tóm tắt bằng AI kèm lưu ý đối chiếu văn bản gốc. Văn bản dài cần xác nhận trước khi tốn hạn mức.
            Kiểm tra căn cứ trích số hiệu trong một văn bản và tra trong kho xem còn hiệu lực, đã sửa đổi hay hết hiệu lực; số hiệu chưa có trong kho được ghi “chưa xác định”. Chế độ không dùng mạng tắt mọi lệnh đi mạng nhưng vẫn tra cứu, tóm tắt (nếu đã lưu) và kiểm tra căn cứ trên văn bản đã tải. Bản tin đầu ngày chỉ tổng hợp dữ liệu có sẵn, không gọi mạng.
            """),
        HelpChapter(id: "tu-hoc", group: "Kỹ năng", title: "Những điều đã học", body: """
            PVTA có thể rút kinh nghiệm từ hội thoại, tài liệu và đánh giá câu trả lời của thầy cô thành bản nháp: mỗi điều kèm đoạn trích nguyên văn làm bằng chứng. Bản nháp chưa duyệt không bao giờ được đưa vào ngữ cảnh. Thầy cô xem nguồn, sửa, rồi duyệt mới bật dùng; xóa thì điều đó biến mất khỏi ngữ cảnh.
            Biên tập nền chạy theo lịch (lỡ lịch thì chạy bù một lần); “Làm ngay” chạy một lượt ngoài lịch và không đổi lịch. Nhập tệp học từ nơi khác luôn vào dạng bản nháp.
            """),
        HelpChapter(id: "plan-quy-trinh", group: "Tự động hóa", title: "Plan và quy trình", body: """
            Plan khảo sát bối cảnh, hỏi thông tin còn thiếu rồi lập kế hoạch; chỉ khi thầy cô bấm “Duyệt và chạy” thì kế hoạch mới thực thi, từng giai đoạn một và dừng chờ duyệt. Quy trình gồm các bước có lời nhắc, model, quyền và bước phải chờ; chạy tuần tự hoặc đa nhánh, từ 1 đến 4 bước đồng thời. Tên chi tiết xem tài liệu kỹ thuật trong thư mục docs.
            """),
        HelpChapter(id: "du-an", group: "Dự án và tra cứu", title: "Dự án, thư mục nguồn và Học hỏi", body: """
            Dự án gom tài liệu theo chủ đề từ nhiều thư mục. Tài liệu hiện tại là nguồn dữ kiện của công việc; thư mục Học hỏi chứa tài liệu các năm trước, chỉ để kế thừa cách viết, bố cục và quy trình. Hai loại được gắn nhãn riêng trong ngữ cảnh; năm, số liệu, tên người trong nguồn cũ không được chép sang tài liệu mới.
            Mỗi lượt nhập tối đa 60 tệp, sâu 8 cấp thư mục. “Đọc lại” cập nhật tệp đã đổi và bỏ tệp đã xóa; “Bỏ liên kết” gỡ khỏi dự án nhưng giữ nguyên tệp. Công tắc riêng cho từng dự án ngừng gửi tài liệu hoặc kinh nghiệm ở lượt AI tiếp theo.
            “Rút kinh nghiệm từ tài liệu” tạo bản nháp để thầy cô xem và sửa rồi mới lưu thành tệp Markdown trong thư mục Học hỏi; nếu tệp đó bị sửa bên ngoài PVTA, PVTA giữ nguyên và báo xung đột. Thư mục Học hỏi nằm trong dự án vẫn bị loại khỏi lần quét tài liệu hiện tại.
            """),
        HelpChapter(id: "tra-cuu-ma", group: "Dự án và tra cứu", title: "Tra cứu mã nguồn (Brain)", body: """
            Với dự án lập trình, PVTA cho AI tra cứu: tổng quan, dàn ý một tệp (cây hàm, lớp có dòng đầu–cuối), tìm theo tên ký hiệu hoặc nội dung, đọc thân hàm và tìm chỗ tham chiếu. Chỉ mục nằm trong thư mục dữ liệu của PVTA, không trong dự án.
            Phạm vi chỉ gồm thư mục đã cấp quyền hoặc đúng các tệp mã đã đính kèm; đính kèm một tệp không mở quyền đọc các tệp cùng thư mục. Thư mục Học hỏi luôn bị loại.
            """),
        HelpChapter(id: "so-nguon", group: "Dự án và tra cứu", title: "Sổ nguồn: hỏi tài liệu và kiểm tra trích dẫn", body: """
            Sổ nguồn gom tệp và trang web để hỏi đáp. Thêm tệp (trong thư mục đã cấp quyền) hoặc địa chỉ https công khai; bật/tắt từng nguồn; làm mới khi tệp hoặc trang đổi; chọn model riêng cho sổ. Câu trả lời đánh số nguồn [1], [2]… và PVTA kiểm tra các số trích dẫn có thật và các đoạn trích nguyên văn có trong nguồn.
            Nguồn bị tắt, đã mất hoặc không đọc được không bao giờ vào ngữ cảnh; nguồn không đủ thì PVTA nói thẳng thay vì đoán. Tra cứu dùng chỉ mục trên máy, hiểu cả chữ có dấu và không dấu.
            """),
        HelpChapter(id: "google-dong-bo", group: "Lịch và Google", title: "Google: kiểm tra đồng bộ và xử lý xung đột", body: """
            Đăng nhập Google bằng trình duyệt, chọn lịch có quyền sửa và danh sách việc rồi xác nhận bật đồng bộ. PVTA đồng bộ lịch, công việc và ghi chú; ghi chú là tệp Markdown riêng của PVTA trên Google Drive. Token đăng nhập chỉ lưu trong Keychain.
            Sau khi sửa trên máy, PVTA chờ khoảng 30 giây để gom thay đổi; đang sửa liên tục thì tối đa 2 phút. Khi lõi đang chạy, PVTA kiểm tra thay đổi từ Google mỗi 5 phút. Có thể yêu cầu đồng bộ ngay và xem số mục chờ, lỗi, lần đồng bộ cuối.
            Nếu cả máy và Google cùng sửa một mục, PVTA giữ cả hai bản để đối chiếu. Chọn giữ bản máy hoặc giữ bản Google sau khi đọc nội dung mới nhất. Nếu Google đổi tiếp trong lúc xem, phải đối chiếu lại; không ghi đè bản chưa xem.
            Khi mất phản hồi lúc tạo công việc, PVTA tìm lại dấu nhận diện trên Google trước khi tạo tiếp. Nếu chưa xác định được kết quả, kiểm tra danh sách việc trên Google rồi mới xác nhận thử tạo lại để tránh trùng.
            Đăng xuất xóa access token và refresh token khỏi Keychain, dừng đồng bộ nhưng giữ lịch cục bộ. Đổi tài khoản không tự gửi các mục thuộc tài khoản cũ sang tài khoản mới. Tệp đính kèm lịch vẫn ở máy; không tự tải lên Drive. Lịch có quy tắc lặp ngoài hằng ngày/hằng tuần hoặc lần lặp sửa riêng chưa được đồng bộ.
            """),
        HelpChapter(id: "xuong-toan", group: "Công cụ chuyên môn", title: "Xưởng Toán và công thức Toán Lý Hóa", body: """
            Xưởng Toán lưu công thức LaTeX theo tên và môn Toán, Lý hoặc Hóa. Có thể đọc lại, sửa và xuất những công thức đã chọn. Mỗi lần sửa tăng phiên bản; nếu cửa sổ khác đã sửa trước thì phải đọc lại, không ghi đè bản mới.
            Phân số, căn, chỉ số, tổng, tích phân và phương trình hóa học được xuất thành Equation chuẩn của Word, có thể chỉnh sửa, không phải ảnh. Công thức hóa học viết trong \\ce{...}; đây là định dạng, không phải chức năng cân bằng hoặc kiểm chứng phản ứng.
            Xuất vào tệp .docx mới trong thư mục đã cấp quyền ghi. Chế độ Hỏi duyệt yêu cầu xem nội dung và đồng ý trước khi tạo tệp. Từ chối hoặc hủy thì không ghi; công thức đổi trong lúc chờ phải xem lại. Tệp trùng tên không bị ghi đè. Chế độ Chỉ đọc không cho lưu hoặc xuất công thức.
            """),
        HelpChapter(id: "github", group: "Dự án và tra cứu", title: "GitHub: xem trước, duyệt và theo dõi", body: """
            Đăng nhập bằng token cá nhân GitHub; token chỉ lưu trong Keychain. Liên kết dự án với thư mục đã cấp quyền, tên kho và nhánh. Có thể xem kho, nhánh, lịch sử, duyệt tệp, tải tệp xuống, cập nhật tệp hoặc tạo nhánh.
            Xem trước chỉ đọc dữ liệu. Khi chạy, PVTA luôn chờ duyệt; cập nhật tệp cần nhập “CẬP NHẬT”, tạo nhánh cần nhập “TẠO NHÁNH”. Bản xem trước hết hạn sau 5 phút. Nguồn, nhánh hoặc quyền đổi thì phải xem lại.
            Tải xuống dùng thư mục mới, không ghi đè; tải lên cập nhật tệp đã chọn trong một lần lưu và giữ các tệp khác. Mỗi lượt tối đa 500 tệp, tổng 100 MB, mỗi tệp 20 MB. Không chuyển liên kết tượng trưng hoặc thư mục .git.
            Nhật ký và lịch sử tải lên giữ cả lượt thành công, lỗi và hủy. Hủy dừng các bước tiếp theo, không hoàn tác bước đã xong. Khi kết quả chưa rõ do mất mạng hoặc lõi dừng, hãy kiểm tra kho trước khi chạy lại. Đăng xuất xóa token và hủy thao tác đang chạy.
            """),
        HelpChapter(id: "tro-giup", group: "Bắt đầu", title: "Sách hướng dẫn và Hỏi PVTA", body: """
            Sách hướng dẫn gồm mục lục theo nhóm và ô tra cứu chấp nhận tiếng Việt có dấu hoặc không dấu. “Hỏi PVTA về chỗ này” trả lời bằng trích đoạn hướng dẫn trên máy: không gọi model AI, không đọc nội dung hội thoại hay giá trị trong ô nhập, chỉ dùng tên chức năng thầy cô nêu.
            Nếu không tìm thấy căn cứ trong hướng dẫn, PVTA đề nghị thầy cô nêu tên chức năng cụ thể thay vì đoán.
            """),
    ]
}
