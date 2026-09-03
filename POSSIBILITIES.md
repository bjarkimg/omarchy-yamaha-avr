# Yamaha AVR YNCA API Capabilities & Future Possibilities

This document catalogues hardware API endpoints and capabilities exposed by Yamaha RX-V and RX-A receivers over the YNCA HTTP XML protocol (`http://RECEIVER/YamahaRemoteControl/ctrl`), discovered via `desc.xml` and live testing on an RX-V677.

These features are documented for future reference and expansion.

---

## 1. Advanced Audio & Tone Controls (Implemented in v1.0.4)
- **Tone Control (Bass / Treble)**:
  - Range: `-6.0 dB` to `+6.0 dB` in `0.5 dB` steps (`-60..+60` in tenths of dB)
  - Fixed turnover frequencies: Bass at `350 Hz`, Treble at `3.5 kHz`
  - XML: `<Main_Zone><Sound_Video><Tone><Bass><Val>{-60..60}</Val><Exp>1</Exp><Unit>dB</Unit></Bass><Treble><Val>{-60..60}</Val><Exp>1</Exp><Unit>dB</Unit></Treble></Tone></Sound_Video></Main_Zone>`
- **Subwoofer Trim**:
  - Range: `-6.0 dB` to `+6.0 dB` in `0.5 dB` steps (`-60..+60`)
  - XML: `<Main_Zone><Volume><Subwoofer_Trim><Val>{-60..60}</Val><Exp>1</Exp><Unit>dB</Unit></Subwoofer_Trim></Volume></Main_Zone>`
- **Extra Bass**:
  - Adds psychoacoustic bass reinforcement to front speakers and subwoofer
  - XML: `<Main_Zone><Sound_Video><Extra_Bass>{Auto|Off}</Extra_Bass></Sound_Video></Main_Zone>`
- **YPAO Volume**:
  - Automatic loudness / frequency compensation curve based on master volume
  - XML: `<Main_Zone><Sound_Video><YPAO_Volume>{Auto|Off}</YPAO_Volume></Sound_Video></Main_Zone>`
- **Adaptive DRC (Dynamic Range Control)**:
  - Compresses dynamic range at lower volumes for late-night dialogue intelligibility
  - XML: `<Main_Zone><Sound_Video><Adaptive_DRC>{Auto|Off}</Adaptive_DRC></Sound_Video></Main_Zone>`
- **Compressed Music Enhancer**:
  - High and low frequency harmonic regeneration for compressed audio/streaming
  - XML: `<Main_Zone><Surround><Program_Sel><Current><Enhancer>{On|Off}</Enhancer></Current></Program_Sel></Surround></Main_Zone>`
- **Dialogue Adjust (Level & Lift)**:
  - Dialogue Level (`0..3`): Midrange vocal presence boost
  - Dialogue Lift (`0..5`): Uses presence speakers to raise sound stage vertically
  - XML: `<Main_Zone><Sound_Video><Dialogue_Adjust><Dialogue_Lift>{0..5}</Dialogue_Lift><Dialogue_Lvl>{0..3}</Dialogue_Lvl></Dialogue_Adjust></Sound_Video></Main_Zone>`
- **CINEMA DSP 3D**:
  - 3D soundfield generation using front presence channels
  - XML: `<Main_Zone><Surround><_3D_Cinema_DSP>{Auto|Off}</_3D_Cinema_DSP></Surround></Main_Zone>`

---

## 2. Sleep Timer
- Available for both Main Zone and Zone 2.
- Options: `Off`, `30 min`, `60 min`, `90 min`, `120 min`.
- XML:
  ```xml
  <Main_Zone>
    <Power_Control>
      <Sleep>30 min</Sleep>
    </Power_Control>
  </Main_Zone>
  ```

---

## 3. Multi-Zone (Zone 2) Control
Independent secondary zone for bedroom, kitchen, or outdoor patio speakers.
- **Power**: `<Zone_2><Power_Control><Power>{On|Standby}</Power></Power_Control></Zone_2>`
- **Volume**: `<Zone_2><Volume><Lvl><Val>{-805..+165}</Val><Exp>1</Exp><Unit>dB</Unit></Lvl></Volume></Zone_2>`
- **Mute**: `<Zone_2><Volume><Mute>{On|Off}</Mute></Volume></Zone_2>`
- **Independent Input**: `<Zone_2><Input><Input_Sel>{AV|AirPlay|Spotify|TUNER|NET_RADIO...}</Input_Sel></Input></Zone_2>`
- **Zone 2 Tone**: Independent Bass and Treble for Zone 2 speakers.
- **Zone 2 Sleep Timer**: Independent sleep timer.

---

## 4. Live Now-Playing Metadata & Media Control
When inputs are set to **AirPlay**, **Spotify**, **NET_RADIO** (Internet Radio/vTuner), or **USB/SERVER (DLNA)**:
- **Metadata**:
  - Artist: `<{Source}><Play_Info><Meta_Info><Artist>`
  - Album: `<{Source}><Play_Info><Meta_Info><Album>`
  - Track: `<{Source}><Play_Info><Meta_Info><Track>`
- **Album Art**:
  - Live thumbnail URL hosted on receiver HTTP server:
    `<{Source}><Play_Info><Album_ART><URL>`
- **Transport Controls**:
  - Play / Pause / Stop: `<{Source}><Play_Control><Playback>{Play|Pause|Stop}</Playback></Play_Control></{Source}>`
  - Skip Forward / Backward: `<{Source}><Play_Control><Plus_Minus>{Skip Fwd|Skip Rev}</Plus_Minus></Play_Control></{Source}>`
  - Repeat & Shuffle: `<{Source}><Play_Control><Play_Mode><Repeat>{Off|One|All}</Repeat><Shuffle>{Off|On}</Shuffle></Play_Mode></Play_Control></{Source}>`

---

## 5. Built-in AM / FM Tuner
- **Direct Preset Recall**: Recalls presets 1 through 40:
  ```xml
  <Tuner>
    <Play_Control>
      <Preset>
        <Preset_Sel>1</Preset_Sel>
      </Preset>
    </Play_Control>
  </Tuner>
  ```
- **Frequency Tuning**: Manual frequency steps and automatic station seeking.

---

## 6. Extended DSP Surround Programs
In addition to Straight, 7ch Stereo, and Pure Direct, Yamaha provides 17 hardware DSP soundfields:
- **Movie**: `Sci-Fi`, `Drama`, `Action Game`, `Roleplaying Game`, `Music Video`, `Standard`, `Spectacle`, `Adventure`, `Mono Movie`
- **Music**: `Hall in Munich`, `Hall in Vienna`, `Chamber`, `Cellar Club`, `The Roxy Theatre`, `The Bottom Line`
- **Decoder**: `Surround Decoder` (Dolby Pro Logic IIx / DTS Neo:6)
- XML:
  ```xml
  <Main_Zone>
    <Surround>
      <Program_Sel>
        <Current>
          <Sound_Program>Drama</Sound_Program>
        </Current>
      </Program_Sel>
    </Surround>
  </Main_Zone>
  ```

---

## 7. On-Screen TV Navigation (Remote Cursor Emulation)
Allows navigating the receiver's on-screen TV menus directly from the desktop:
- Actions: `Cursor Up`, `Cursor Down`, `Cursor Left`, `Cursor Right`, `Cursor Select`, `Return to Home`.
- XML:
  ```xml
  <Main_Zone>
    <List_Control>
      <Cursor>Up</Cursor>
    </List_Control>
  </Main_Zone>
  ```
