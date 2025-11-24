UNIT HeartWare.Clipboard;

INTERFACE

{.$DEFINE HW }

USES WinAPI.Windows, WinAPI.Messages,
     System.Classes, System.SysUtils,
     VCL.Controls,
     VCL.Clipbrd
     {$IFDEF HW }
       ,HeartWare.FileFuncs
     {$ENDIF };

TYPE
  {$IFDEF HW }
    TFileNames          = TPathStrArr;
  {$ELSE }
    TFileNames          = TArray<TFileName>;
    TFileNamesHelper    = RECORD HELPER FOR TFileNames
                          PRIVATE
                            FUNCTION    GetLen : INTEGER; INLINE;
                            PROCEDURE   SetLen(Value : INTEGER); INLINE;
                          PUBLIC
                            CONST       LOW = INTEGER(0);
                            FUNCTION    HIGH : INTEGER; INLINE;
                            PROPERTY    LENGTH : INTEGER Read GetLen Write SetLen;
                            FUNCTION    Count : Cardinal; INLINE;
                            FUNCTION    IsEmpty : BOOLEAN; INLINE;
                            FUNCTION    ValidIndex(Index : INTEGER) : BOOLEAN;
                            FUNCTION    IndexOf(CONST N : TFileName) : INTEGER;
                            FUNCTION    Contains(CONST N : TFileName) : BOOLEAN;
                            FUNCTION    Append(CONST N : TFileName) : INTEGER;
                            FUNCTION    Add(CONST N : TFileName) : INTEGER;
                            PROCEDURE   Clear; INLINE;
                          END;
  {$ENDIF }
  TClipboard            = CLASS(VCL.Clipbrd.TClipboard)
                            DESTRUCTOR          Destroy; OVERRIDE;
                          PRIVATE TYPE
                            TUpdateEvent        = REFERENCE TO PROCEDURE(Sender : TClipboard ; VAR Done : BOOLEAN);
                            TMsgWindow          = CLASS(TWinControl)
                                                    CONSTRUCTOR Create(Clip : TClipboard); REINTRODUCE;
                                                    DESTRUCTOR  Destroy; OVERRIDE;
                                                  PROTECTED
                                                    PROCEDURE   CreateParams(VAR Params : TCreateParams); OVERRIDE;
                                                  PRIVATE
                                                    FClip       : TClipboard;
                                                    PROCEDURE   Update(VAR MSG : TMessage); REINTRODUCE; MESSAGE WM_CLIPBOARDUPDATE;
                                                  PUBLIC
                                                    PROPERTY    Clip : TClipboard Read FClip;
                                                  END;
                          PRIVATE
                            FOnUpdate           : TUpdateEvent;
                            MsgWindow           : TMsgWindow;
                            PROCEDURE           Hook;
                            PROCEDURE           Unhook;
                            PROCEDURE           SetUpdate(Value : TUpdateEvent);
                            FUNCTION            GetFile : TFileName;
                            FUNCTION            GetFiles(Max : UINT) : TFileNames; OVERLOAD;
                            FUNCTION            GetFiles : TFileNames; OVERLOAD;
                            PROCEDURE           SetFile(CONST Value : TFileName); INLINE;
                            PROCEDURE           SetFiles(CONST Value : TFileNames);
                            FUNCTION            GetComponent : TComponent;
                          PUBLIC
                            PROPERTY            AsFile : TFileName Read GetFile Write SetFile;
                            PROPERTY            AsFiles : TFileNames Read GetFiles Write SetFiles;
                            PROPERTY            AsComponent : TComponent Read GetComponent Write SetComponent;
                            PROPERTY            OnUpdate : TUpdateEvent Read FOnUpdate Write SetUpdate;
                          END;

FUNCTION Clipboard : TClipboard;

IMPLEMENTATION

USES WinAPI.ShellAPI, WinAPI.ShlObj,
     VCL.Forms;

{ TClipboard }

VAR ClipBrd : TClipboard = NIL;

FUNCTION Clipboard : TClipboard;
  BEGIN
    IF NOT Assigned(ClipBrd) THEN BEGIN
      ClipBrd:=TClipboard.Create;
      SetClipboard(ClipBrd).Free
    END;
    Result:=ClipBrd
  END;

DESTRUCTOR TClipboard.Destroy;
  BEGIN
    Unhook;
    INHERITED;
    ClipBrd:=NIL
  END;

FUNCTION TClipboard.GetComponent : TComponent;
  BEGIN
    IF HasFormat(CF_COMPONENT) THEN Result:=INHERITED GetComponent(NIL,NIL) ELSE Result:=NIL
  END;

FUNCTION TClipboard.GetFile : TFileName;
  BEGIN
    VAR ARR := GetFiles(1);
    IF ARR.IsEmpty THEN Result:='' ELSE Result:=ARR[ARR.LOW]
  END;

FUNCTION TClipboard.GetFiles(Max : UINT) : TFileNames;
  VAR
    hDrop       : WinAPI.ShellAPI.HDROP;
    FileCount,I : UINT;
    Len         : UINT;
    S           : TFileName;

  BEGIN
    Result.Clear;
    IF NOT HasFormat(CF_HDROP) THEN EXIT;  // no file objects on clipboard

    Open;
    TRY
      hDrop:=GetAsHandle(CF_HDROP);
      IF hDrop=0 THEN EXIT;

      // Number of files in the drop
      FileCount:=DragQueryFile(hDrop,$FFFFFFFF,NIL,0);
      IF FileCount=0 THEN EXIT;

      FOR I:=0 TO PRED(FileCount) DO BEGIN
        IF Result.Count>=Max THEN BREAK;
        Len:=DragQueryFile(hDrop,I,NIL,0);
        SetLength(S,Len);
        IF Len>0 THEN DragQueryFile(hDrop,I,PChar(S),SUCC(Len));
        IF FileExists(S) THEN Result.Append(S)
      END
    FINALLY
      Close
    END
  END;

FUNCTION TClipboard.GetFiles : TFileNames;
  BEGIN
    Result:=GetFiles(MAXINT)
  END;

PROCEDURE TClipboard.Hook;
  BEGIN
    IF NOT Assigned(MsgWindow) THEN
      TThread.Synchronize(NIL,PROCEDURE // Make sure window is created on Main Thread
                                BEGIN
                                  MsgWindow:=TMsgWindow.Create(Self)
                                END)
  END;

PROCEDURE TClipboard.SetFile(CONST Value : TFileName);
  BEGIN
    SetFiles([Value])
  END;

PROCEDURE TClipboard.SetFiles(CONST Value : TFileNames);
  VAR
    I           : Integer;
    TotalChars  : Integer;
    MemSize     : Integer;
    hMem        : HGLOBAL;
    pDrop       : PDROPFILES;
    pData       : PChar;
    Files       : STRING;
    FileName    : TFileName;
    ANSI        : AnsiString;

  BEGIN
    IF Value.IsEmpty THEN EXIT;

    // Count total characters needed for the multi-string: "file1#0file2#0...#0#0"
    TotalChars:=0;
    FOR I:=Value.LOW to Value.HIGH DO INC(TotalChars,SUCC(StrLen(PChar(Value[i]))));  // SUCC for #0 after each file name
    INC(TotalChars);                                                                  // Final extra #0 terminator

    MemSize:=SizeOf(DROPFILES)+TotalChars*SizeOf(Char);

    // CF_HDROP requires a moveable global memory block
    hMem:=GlobalAlloc(GMEM_MOVEABLE OR GMEM_ZEROINIT,MemSize);
    IF hMem=0 THEN RaiseLastOSError;

    pDrop:=GlobalLock(hMem);
    IF NOT Assigned(pDrop) THEN BEGIN
      GlobalFree(hMem);
      RaiseLastOSError
    END;

    TRY
      // Fill the DROPFILES header
      pDrop.pFiles:=SizeOf(DROPFILES);  // offset to file list
      pDrop.pt.x  :=0;
      pDrop.pt.y  :=0;
      pDrop.fNC   :=FALSE;
      pDrop.fWide :=TRUE;               // We’re writing Unicode file names

      // Pointer to the first filename (right after DROPFILES)
      pData:=PChar(PByte(pDrop)+pDrop.pFiles);

      // Copy each file name, each zero terminated
      Files:='';
      FOR I:=Value.LOW TO Value.HIGH DO BEGIN
        FileName:=Value[I];
        IF FileExists(FileName) THEN BEGIN
          IF NOT Files.IsEmpty THEN Files:=Files+#13;
          Files:=Files+FileName;
          StrCopy(pData,PChar(FileName));
          INC(pData,SUCC(LENGTH(Value[i])))
        END
      END;

      // Add final #0 for the multi-string terminator
      pData^:=#0
    FINALLY
      GlobalUnlock(hMem)
    END;

    Open;
    TRY
      // Put the CF_HDROP handle on the clipboard
      SetAsHandle(CF_HDROP,hMem);
      // Also put CF_UNICODETEXT format on the clipboard
      SetBuffer(CF_UNICODETEXT,PChar(Files)^,LENGTH(Files)*SizeOf(CHAR));
      // And CF_TEXT (ANSI) format on the clipboard
      ANSI:=AnsiString(Files);
      SetBuffer(CF_TEXT,PAnsiChar(ANSI)^,LENGTH(ANSI)*SizeOf(AnsiChar));
      // Do NOT GlobalFree(hMem); clipboard owns it now
    FINALLY
      Close
    END
  END;

PROCEDURE TClipboard.SetUpdate(Value : TUpdateEvent);
  BEGIN
    FOnUpdate:=Value;
    IF Assigned(Value) THEN Hook ELSE Unhook
  END;

PROCEDURE TClipboard.Unhook;
  BEGIN
    FreeAndNIL(MsgWindow)
  END;

{ TClipboard.TMsgWindow }

CONSTRUCTOR TClipboard.TMsgWindow.Create(Clip : TClipboard);
  BEGIN
    INHERITED Create(NIL);
    FClip:=Clip;
    ControlStyle:=ControlStyle+[csAcceptsControls];
    Visible:=FALSE;
    AddClipboardFormatListener(Handle)
  END;

PROCEDURE TClipboard.TMsgWindow.CreateParams(VAR Params : TCreateParams);
  BEGIN
    INHERITED;
    Params.Style:=0; Params.ExStyle:=0;
    Params.X:=0; Params.Y:=0;
    Params.Width:=0; Params.Height:=0;
    // This is the crucial part:
    Params.WndParent:=HWND_MESSAGE  // Makes it a message-only window
  END;

DESTRUCTOR TClipboard.TMsgWindow.Destroy;
  BEGIN
    RemoveClipboardFormatListener(Handle);
    INHERITED;
    Clip.MsgWindow:=NIL
  END;

PROCEDURE TClipboard.TMsgWindow.Update(VAR MSG : TMessage); // Always called on Main Thread (since window is created in main thread)
  VAR
    Done        : BOOLEAN;

  BEGIN
    ASSERT(Assigned(Clip));
    ASSERT(Assigned(Clip.OnUpdate));
    Done:=TRUE;
    Clip.FOnUpdate(Clip,Done);
    MSG.Result:=ORD(NOT Done)
  END;

{$IFNDEF HW }
{ TFileNamesHelper }

FUNCTION TFileNamesHelper.Add(CONST N : TFileName) : INTEGER;
  BEGIN
    Result:=IndexOf(N);
    IF NOT ValidIndex(Result) THEN Result:=Append(N)
  END;

FUNCTION TFileNamesHelper.Append(CONST N : TFileName) : INTEGER;
  BEGIN
    Self:=Self+[N]; Result:=HIGH
  END;

PROCEDURE TFileNamesHelper.Clear;
  BEGIN
    LENGTH:=0
  END;

FUNCTION TFileNamesHelper.Contains(CONST N : TFileName) : BOOLEAN;
  BEGIN
    Result:=ValidIndex(IndexOf(N))
  END;

FUNCTION TFileNamesHelper.Count : Cardinal;
  BEGIN
    Result:=Cardinal(LENGTH)
  END;

FUNCTION TFileNamesHelper.GetLen : INTEGER;
  BEGIN
    Result:=System.LENGTH(Self)
  END;

FUNCTION TFileNamesHelper.HIGH : INTEGER;
  BEGIN
    Result:=System.HIGH(Self)
  END;

FUNCTION TFileNamesHelper.IndexOf(CONST N : TFileName) : INTEGER;
  FUNCTION SameFileName(CONST N1,N2 : TFileName) : BOOLEAN; INLINE;
    BEGIN
      {$IFDEF UNIX }
        Result:=(AnsiCompareStr(N1,N2)=0)       // Case-Sensitive Comparison
      {$ELSE }
        Result:=SameText(N1,N2)                 // Case-Insensitive Comparison
      {$ENDIF }
    END;

  BEGIN
    FOR Result:=LOW TO HIGH DO IF SameFileName(N,Self[Result]) THEN EXIT;
    Result:=PRED(LOW)
  END;

FUNCTION TFileNamesHelper.IsEmpty : BOOLEAN;
  BEGIN
    Result:=(Count=0)
  END;

PROCEDURE TFileNamesHelper.SetLen(Value : INTEGER);
  BEGIN
    SetLength(Self,Value)
  END;

FUNCTION TFileNamesHelper.ValidIndex(Index : INTEGER) : BOOLEAN;
  BEGIN
    Result:=(Index>=LOW) AND (Index<=HIGH)
  END;
{$ENDIF }

END.
