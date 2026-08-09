{*******************************************************************************
  Fluid Magma Effect
  A real-time particle-based fluid simulation with a metaball-style rendering
  effect. Uses background threading for physics calculations and Skia4Delphi
  for high-performance graphics rendering.
*******************************************************************************}
unit uFluidMagmaEffect;

interface

uses
  System.SysUtils, System.Types, System.Classes, System.Math, System.SyncObjs,
  System.UITypes, FMX.Types, FMX.Controls, FMX.Graphics, FMX.Skia, System.Skia;

type
  /// <summary>
  /// Represents a single particle in the fluid simulation grid.
  /// Contains current position, velocity, and its original anchor point.
  /// </summary>
  TParticle = record
    X, Y: Single;
    VelX, VelY: Single;
    AnchorX, AnchorY: Single;
  end;

  /// <summary>
  /// Interactive Fluid Magma control. Renders a dot matrix background
  /// and a fluid blob mass that reacts to mouse input.
  /// </summary>
  TFluidMagmaEffect = class(TSkCustomControl)
  private
    FThread: TThread;
    FLock: TCriticalSection;
    FActive: Boolean;
    FIntensity: Single;
    FOffscreenSurface: ISkSurface;
    FLastWidth, FLastHeight: Integer;
    FMagmaPath: ISkPath;
    FMousePos: TPointF;
    FIsMouseOver: Boolean;
    FCurrentWidth, FCurrentHeight: Single;
    FParticles: array of TParticle;

    procedure SetIntensity(const Value: Single);
    procedure SetActive(const Value: Boolean);
    procedure SafeInvalidate;
    procedure DoRedraw;
    procedure StartThread;
    procedure StopThread;
    procedure InitParticles(const W, H: Single);
  protected
    procedure Resize; override;
    procedure Draw(const ACanvas: ISkCanvas; const ADest: TRectF; const AOpacity: Single); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Single); override;
    procedure DoMouseLeave; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    property Active: Boolean read FActive write SetActive;
    property Intensity: Single read FIntensity write SetIntensity;
  end;

implementation

/// <summary>
/// Helper function to linearly interpolate between two colors.
/// Used for dynamic background dot coloring based on intensity.
/// </summary>

function LerpColor(C1, C2: TAlphaColor; t: Single): TAlphaColor;
var
  R1, G1, B1, R2, G2, B2: Byte;
begin
  R1 := (C1 shr 16) and $FF;
  G1 := (C1 shr 8) and $FF;
  B1 := C1 and $FF;
  R2 := (C2 shr 16) and $FF;
  G2 := (C2 shr 8) and $FF;
  B2 := C2 and $FF;
  Result := $FF000000 or (Round(R1 + (R2 - R1) * t) shl 16) or (Round(G1 + (G2 - G1) * t) shl 8) or (Round(B1 + (B2 - B1) * t));
end;

{ TFluidMagmaEffect }

constructor TFluidMagmaEffect.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FLock := TCriticalSection.Create;
  Align := TAlignLayout.Client;
  HitTest := True; // Enable mouse events for interaction

  FIntensity := 0.0;
  FActive := True;
  FIsMouseOver := False;
  FCurrentWidth := 100;
  FCurrentHeight := 100;
  FMousePos := TPointF.Create(0, 0);

  StartThread;
end;

destructor TFluidMagmaEffect.Destroy;
begin
  StopThread;
  FreeAndNil(FLock);
  inherited;
end;

procedure TFluidMagmaEffect.SetActive(const Value: Boolean);
begin
  FActive := Value;
end;

procedure TFluidMagmaEffect.SetIntensity(const Value: Single);
begin
  if FIntensity <> Value then
  begin
    FIntensity := EnsureRange(Value, 0.0, 1.0);
    Redraw;
  end;
end;

procedure TFluidMagmaEffect.Resize;
begin
  inherited;
  FLock.Acquire;
  try
    FCurrentWidth := Width;
    FCurrentHeight := Height;

    if (FCurrentWidth > 0) and (FCurrentHeight > 0) then
    begin
      // Recreate offscreen surface and particle grid only if dimensions changed
      if (FLastWidth <> Round(FCurrentWidth)) or (FLastHeight <> Round(FCurrentHeight)) then
      begin
        FLastWidth := Round(FCurrentWidth);
        FLastHeight := Round(FCurrentHeight);
        FOffscreenSurface := TSkSurface.MakeRaster(TSkImageInfo.Create(FLastWidth, FLastHeight));
        InitParticles(FCurrentWidth, FCurrentHeight);
      end;
    end;
  finally
    FLock.Release;
  end;
  Redraw;
end;

procedure TFluidMagmaEffect.DoRedraw;
begin
  if not (csDestroying in ComponentState) then
    Redraw;
end;

procedure TFluidMagmaEffect.SafeInvalidate;
begin
  if csDestroying in ComponentState then
    Exit;
  // Thread-safe UI update queue
  TThread.Queue(nil, DoRedraw);
end;

/// <summary>
/// Initializes a grid of particles (8x5) positioned in the center of the control.
/// </summary>
procedure TFluidMagmaEffect.InitParticles(const W, H: Single);
const
  Cols = 8;
  Rows = 5;
var
  i, j, Idx: Integer;
  StartX, StartY, SpaceX, SpaceY: Single;
begin
  SetLength(FParticles, Cols * Rows);

  // Define grid boundaries
  StartX := W * 0.25;
  StartY := H * 0.3;
  SpaceX := (W * 0.5) / (Cols - 1);
  SpaceY := (H * 0.4) / (Rows - 1);

  Idx := 0;
  for i := 0 to Cols - 1 do
  begin
    for j := 0 to Rows - 1 do
    begin
      FParticles[Idx].AnchorX := StartX + (i * SpaceX);
      FParticles[Idx].AnchorY := StartY + (j * SpaceY);
      FParticles[Idx].X := FParticles[Idx].AnchorX;
      FParticles[Idx].Y := FParticles[Idx].AnchorY;
      FParticles[Idx].VelX := 0;
      FParticles[Idx].VelY := 0;
      Inc(Idx);
    end;
  end;
end;

procedure TFluidMagmaEffect.StartThread;
begin
  if Assigned(FThread) then
    Exit;

  // Background thread for continuous physics simulation
  FThread := TThread.CreateAnonymousThread(
    procedure
    var
      LastTime, NowTime: Cardinal;
      DeltaMS: Cardinal;
      LW, LH: Single;
      LBuilder: ISkPathBuilder;
      i: Integer;

      // Physics variables
      Ldx, Ldy, LDist, LForce, LRepelRadius: Single;
      LTargetX, LTargetY: Single;
      LRadius: Single;
      LPnt: TPointF;
    begin
      LastTime := TThread.GetTickCount;

      while not TThread.CheckTerminated do
      begin
        NowTime := TThread.GetTickCount;
        DeltaMS := NowTime - LastTime;
        if DeltaMS = 0 then
          DeltaMS := 1;
        LastTime := NowTime;

        if FActive then
        begin
          FLock.Acquire;
          try
            LW := FCurrentWidth;
            LH := FCurrentHeight;

            if (LW > 0) and (LH > 0) and (Length(FParticles) > 0) then
            begin
              // Calculate interaction radii based on control width
              LRepelRadius := LW * 0.15; // Mouse "snowplow" radius
              LRadius := LW * 0.06;       // Base radius of individual blobs

              // 1. UPDATE FLUID PHYSICS
              for i := 0 to High(FParticles) do
              begin
                LTargetX := FParticles[i].AnchorX;
                LTargetY := FParticles[i].AnchorY;

                // A) Mouse Repulsion (Snowplow Effect)
                if FIsMouseOver then
                begin
                  Ldx := FParticles[i].X - FMousePos.X;
                  Ldy := FParticles[i].Y - FMousePos.Y;
                  LDist := Sqrt(Ldx * Ldx + Ldy * Ldy);

                  if LDist < LRepelRadius then
                  begin
                    LForce := (1.0 - (LDist / LRepelRadius));
                    LForce := LForce * LForce * 30.0; // Apply quadratic force

                    if LDist > 0 then
                    begin
                      FParticles[i].VelX := FParticles[i].VelX + (Ldx / LDist) * LForce;
                      FParticles[i].VelY := FParticles[i].VelY + (Ldy / LDist) * LForce;
                    end;
                  end;
                end;

                // B) Spring back to anchor point (Fluid return)
                Ldx := LTargetX - FParticles[i].X;
                Ldy := LTargetY - FParticles[i].Y;
                FParticles[i].VelX := FParticles[i].VelX + Ldx * 0.05;
                FParticles[i].VelY := FParticles[i].VelY + Ldy * 0.05;

                // C) Apply friction to prevent endless oscillation
                FParticles[i].VelX := FParticles[i].VelX * 0.85;
                FParticles[i].VelY := FParticles[i].VelY * 0.85;

                // D) Update position
                FParticles[i].X := FParticles[i].X + FParticles[i].VelX;
                FParticles[i].Y := FParticles[i].Y + FParticles[i].VelY;
              end;

              // 2. BUILD MAGMA PATH (Overlapping circles for metaball look)
              LBuilder := TSkPathBuilder.Create;
              LBuilder.FillType := TSkPathFillType.Winding;

              for i := 0 to High(FParticles) do
              begin
                // Add slight pulsation for a more organic feel
                LPnt := TPointF.Create(FParticles[i].X, FParticles[i].Y);
                LBuilder.AddCircle(LPnt.X, LPnt.Y, LRadius + Sin(NowTime * 0.003 + i) * 2.0);
              end;

              FMagmaPath := LBuilder.Detach;
            end;
          finally
            FLock.Release;
          end;

          SafeInvalidate;
        end;

        // Target ~30 FPS for physics calculations
        Sleep(32);
      end;
    end);

  FThread.FreeOnTerminate := True;
  FThread.Start;
end;

procedure TFluidMagmaEffect.StopThread;
begin
  FActive := False;
  if Assigned(FThread) then
  begin
    FThread.Terminate;
    Sleep(50); // Allow thread to safely exit
  end;
end;

procedure TFluidMagmaEffect.MouseMove(Shift: TShiftState; X, Y: Single);
begin
  inherited;
  FMousePos := TPointF.Create(X, Y);
  FIsMouseOver := True;
end;

procedure TFluidMagmaEffect.DoMouseLeave;
begin
  inherited;
  FIsMouseOver := False;
end;

procedure TFluidMagmaEffect.Draw(const ACanvas: ISkCanvas; const ADest: TRectF; const AOpacity: Single);
var
  LDotPaint, LBlurPaint, LBlackPaint: ISkPaint;
  LBlur: ISkImageFilter;
  LMatrix: TSkColorMatrix;
  LShadowDown, LShadowUp, LCombinedShadow: ISkImageFilter;
  x, y: Integer;
  LSurface: ISkSurface;
  LMagmaImg: ISkImage;
  LW, LH: Integer;
  LPoint: TPointF;
  LRadius: Single;
  LColor, DarkBlue, BrightBlue: TAlphaColor;
  LLocalPath: ISkPath;
begin
  LW := Trunc(Width);
  LH := Trunc(Height);
  if (LW <= 0) or (LH <= 0) or (FOffscreenSurface = nil) then
    Exit;

  // 1. DRAW DOT RASTER BACKGROUND
  ACanvas.Clear(TAlphaColors.Black);
  LDotPaint := TSkPaint.Create;
  LDotPaint.AntiAlias := True;

  DarkBlue := $FF050015;
  BrightBlue := $FF0055FF;

  for x := 0 to (LW div 10) do
  begin
    for y := 0 to (LH div 10) do
    begin
      LRadius := 2.0 + (FIntensity * 2.0);
      LColor := LerpColor(DarkBlue, BrightBlue, FIntensity);
      LDotPaint.Color := LColor;
      LPoint := TPointF.Create(x * 10, y * 10);
      ACanvas.DrawCircle(LPoint, LRadius, LDotPaint);
    end;
  end;

  // 2. RENDER MAGMA ON OFFSCREEN SURFACE
  LSurface := FOffscreenSurface;
  LSurface.Canvas.Clear(TAlphaColors.Null);

  // Safely copy the path generated by the background thread
  FLock.Acquire;
  try
    LLocalPath := FMagmaPath;
  finally
    FLock.Release;
  end;

  if LLocalPath <> nil then
  begin
    // Apply blur to merge individual circles into a unified fluid mass
    LBlur := TSkImageFilter.MakeBlur(LW * 0.012, LW * 0.012, nil, TSkTileMode.Decal);
    LBlurPaint := TSkPaint.Create;
    LBlurPaint.AntiAlias := True;
    LBlurPaint.Color := TAlphaColors.White;
    LBlurPaint.ImageFilter := LBlur;
    LSurface.Canvas.DrawPath(LLocalPath, LBlurPaint);
  end;

  LMagmaImg := LSurface.MakeImageSnapshot;

  // 3. APPLY COLOR FILTER & DROP SHADOWS
  LBlackPaint := TSkPaint.Create;
  LBlackPaint.AntiAlias := True;

  // Color matrix to turn the white blurred shape into a dark magma base
  LMatrix := TSkColorMatrix.Create(0, 0, 0, 0, 0.03, 0, 0, 0, 0, 0.01, 0, 0, 0, 0, 0.04, 1, 0, 0, 0, 0);
  LBlackPaint.ColorFilter := TSkColorFilter.MakeMatrix(LMatrix);

  // Generate dynamic shadows for depth perception
  LShadowDown := TSkImageFilter.MakeDropShadow(0, LH * 0.02, LW * 0.03, LW * 0.03, TAlphaColors.Black, nil);
  LShadowUp := TSkImageFilter.MakeDropShadow(0, -LH * 0.01, LW * 0.02, LW * 0.02, TAlphaColors.Black, nil);
  LCombinedShadow := TSkImageFilter.MakeCompose(LShadowUp, LShadowDown);
  LBlackPaint.ImageFilter := LCombinedShadow;

  // Draw final composited magma image to the main canvas
  ACanvas.DrawImage(LMagmaImg, 0, 0, LBlackPaint);
end;

end.

