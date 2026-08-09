unit Unit9;

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes, System.Variants,
  FMX.Types, FMX.Controls, FMX.Forms, FMX.Graphics, FMX.Dialogs, FMX.StdCtrls,
  FMX.Layouts, uFluidMagmaEffect;

type
  TForm9 = class(TForm)
    procedure FormCreate(Sender: TObject);
  private
    FMagma: TFluidMagmaEffect;
    FTrackBar: TTrackBar;
    procedure TrackBarChange(Sender: TObject);
  public
    { Public-Deklarationen }
  end;

var
  Form9: TForm9;

implementation
{$R *.fmx}

procedure TForm9.FormCreate(Sender: TObject);
var
  LLayout: TLayout;
begin
  Caption := 'Fluid Magma';
  Width := 800;
  Height := 600;
  Position := TFormPosition.ScreenCenter;
  FMagma := TFluidMagmaEffect.Create(Self);
  FMagma.Parent := Self;
  FMagma.Align := TAlignLayout.Client;
  FMagma.Intensity := 0.5;
  FMagma.Active := True;
  LLayout := TLayout.Create(Self);
  LLayout.Parent := Self;
  LLayout.Align := TAlignLayout.Bottom;
  LLayout.Height := 50;
  FTrackBar := TTrackBar.Create(Self);
  FTrackBar.Parent := LLayout;
  FTrackBar.Align := TAlignLayout.Client;
  FTrackBar.Margins.Left := 20;
  FTrackBar.Margins.Right := 20;
  FTrackBar.Margins.Top := 10;
  FTrackBar.Margins.Bottom := 10;
  FTrackBar.Min := 0;
  FTrackBar.Max := 100;
  FTrackBar.Value := 50;
  FTrackBar.OnChange := TrackBarChange;
end;

procedure TForm9.TrackBarChange(Sender: TObject);
begin
  if Assigned(FMagma) then
    FMagma.Intensity := FTrackBar.Value / 100;
end;

end.

