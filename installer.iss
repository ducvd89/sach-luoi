; Bộ cài đặt Windows cho ứng dụng Sách lười.
;
; Dựng bằng Inno Setup 6:
;   "%LOCALAPPDATA%\Programs\Inno Setup 6\ISCC.exe" installer.iss
;
; Chạy dong-goi.ps1 trước để có sẵn dist\SachLuoi.
;
; Cài theo từng người dùng chứ không vào Program Files, để khỏi phải xin quyền
; quản trị. Mô hình giọng nói nằm trong thư mục dữ liệu người dùng, không nằm ở
; đây, nên thư mục cài chỉ khoảng 120 MB.

#define AppName "Sách lười"
#define AppVersion "1.3.1"
#define AppPublisher "Sách lười"
#define AppExe "SachLuoi.exe"
#define SourceDir "dist\SachLuoi"

[Setup]
AppId={{7C1E9F2A-4B83-4D16-9C5E-8A1F3D6B2E47}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={autopf}\SachLuoi
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
DisableDirPage=no
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=dist
OutputBaseFilename=SachLuoi-Setup-{#AppVersion}
SetupIconFile=app\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
; Sách lười cần chỗ cho thư viện và bộ nhớ đệm âm thanh; báo trước cho rõ.
ExtraDiskSpaceRequired=52428800

[Languages]
Name: "vi"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Tạo biểu tượng ngoài màn hình nền"; GroupDescription: "Biểu tượng:"

; Cài chồng lên bản tên cũ: bỏ exe và lối tắt cũ, không thì máy có hai biểu
; tượng cùng trỏ vào một thư mục dữ liệu.
[InstallDelete]
Type: files; Name: "{app}\SachNoi.exe"
Type: files; Name: "{group}\Sách nói tiếng Việt.lnk"
Type: files; Name: "{group}\Gỡ Sách nói tiếng Việt.lnk"
Type: files; Name: "{autodesktop}\Sách nói tiếng Việt.lnk"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{group}\Gỡ {#AppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "Mở {#AppName} ngay"; Flags: nowait postinstall skipifsilent

[Messages]
SetupAppTitle=Cài đặt
SetupWindowTitle=Cài đặt %1
WelcomeLabel1=Cài đặt [name]
WelcomeLabel2=Ứng dụng sẽ được cài vào máy của bạn.%n%nỨng dụng đọc sách EPUB và TXT thành sách nói tiếng Việt, chạy hoàn toàn trên máy, không cần mạng.%n%nNên đóng các chương trình khác trước khi tiếp tục.
ClickNext=Bấm Next để tiếp tục, hoặc Cancel để thoát.
SelectDirDesc=Cài [name] vào đâu?
SelectDirLabel3=Ứng dụng sẽ được cài vào thư mục dưới đây.
SelectDirBrowseLabel=Bấm Next để tiếp tục. Muốn đổi chỗ khác thì bấm Browse.
DiskSpaceGBLabel=Cần ít nhất [gb] GB trống trên đĩa.
DiskSpaceMBLabel=Cần ít nhất [mb] MB trống trên đĩa.
ReadyLabel1=Đã sẵn sàng cài [name] vào máy.
ReadyLabel2a=Bấm Install để bắt đầu, hoặc Back để xem lại các lựa chọn.
ReadyMemoTasks=Việc thêm:
ReadyMemoDir=Thư mục cài:
WizardPreparing=Đang chuẩn bị
WizardInstalling=Đang cài đặt
InstallingLabel=Đang chép file vào máy, chờ một chút.
StatusExtractFiles=Đang giải nén...
FinishedHeadingLabel=Đã cài xong [name]
FinishedLabel=Ứng dụng đã được cài vào máy.%n%nMở lên, vào Cài đặt và bấm "Tải mô hình" một lần (khoảng 206 MB). Sau đó đọc sách được hoàn toàn không cần mạng.
FinishedLabelNoIcons=Đã cài xong [name].
ClickFinish=Bấm Finish để đóng.
ConfirmUninstall=Gỡ %1 khỏi máy?
UninstalledAll=Đã gỡ %1 khỏi máy.
ExitSetupTitle=Thoát cài đặt
ExitSetupMessage=Chưa cài xong. Thoát bây giờ thì ứng dụng chưa dùng được.%n%nVẫn thoát?

[Code]
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  DataDir: String;
begin
  if CurUninstallStep = usPostUninstall then
  begin
    // Thư viện sách và tiến trình nghe nằm ngoài thư mục cài. Mặc định giữ lại
    // để cài lại là nghe tiếp đúng chỗ; chỉ xoá khi người dùng chủ động chọn.
    DataDir := ExpandConstant('{userappdata}\com.sachnoi');
    if DirExists(DataDir) then
    begin
      if MsgBox('Xoá luôn thư viện sách, tiến trình nghe và các gói giọng đã tải?'#13#10#13#10
                + 'Chọn No nếu bạn còn định cài lại.',
                mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES then
        DelTree(DataDir, True, True, True);
    end;
  end;
end;
