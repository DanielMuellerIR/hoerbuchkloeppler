# Third-Party Notices

Hörbuchklöppler nutzt die unten aufgeführte Drittsoftware. Für jede Komponente
sind Lizenz und der vollständige Lizenztext bzw. Copyright-Vermerk wiedergegeben.

**Wichtig zur Einordnung:** Dieses Repository verteilt **keine** Drittbinaries.
`ffmpeg` und `mediainfo` liegen bewusst nicht im Repo — `build.sh` lädt sie beim
Bauen vom jeweiligen offiziellen Upstream auf den Rechner des Bauenden, und erst
die **lokal gebaute** App bündelt sie. Deshalb bietet dieses Projekt auch keine
vorgebauten `.app`-/`.dmg`-Downloads an (Details unten unter „ffmpeg“).

Hörbuchklöppler selbst steht unter der MIT-Lizenz, © 2026 Daniel Müller
(siehe `LICENSE`). Das App-Icon ist eine Eigenarbeit dieses Projekts und fällt
unter dieselbe Lizenz.

Stand: 2026-07-19.

## Übersicht

| Komponente | Verwendung | Bezug | Lizenz |
|---|---|---|---|
| ffmpeg (evermeet.cx-Build, „tessus“) | Audio-Slicing, Encoding, Muxing (separater Subprozess) | von `build.sh` beim Bauen geladen; von der lokal gebauten App gebündelt | **GPL-3.0** (Build mit `--enable-gpl --enable-version3`) |
| MediaInfo CLI | Metadaten-/Bitraten-Auslesen (separater Subprozess) | von `build.sh` beim Bauen geladen; von der lokal gebauten App gebündelt | BSD-2-Clause |
| swift-argument-parser | CLI-Parsing (nur `kloeppler`, statisch gelinkt) | von SwiftPM beim Bauen geladen | Apache-2.0 mit Runtime Library Exception |
| Hörprobe (LibriVox-Aufnahme) | A/B-Klangbeispiel als Release-Asset | GitHub-Release-Asset, nicht im Repo | Public Domain |

Versionsstand beim Verfassen: ffmpeg 8.1.2-tessus, MediaInfo CLI 26.05,
swift-argument-parser ≥ 1.3.0 (SwiftPM löst die konkrete Version auf).
`build.sh` lädt jeweils den aktuellen Upstream-Stand; die tatsächlich
gebündelten Versionen können daher neuer sein (`ffmpeg -version` bzw.
`mediainfo --Version` im gebauten Bundle zeigt sie an).

---

## ffmpeg

- **Lizenz des Binaries: GPL-3.0.** FFmpeg selbst ist LGPL-2.1-or-later; der von
  `build.sh` geladene evermeet.cx-Build ist jedoch mit `--enable-gpl` (GPL-
  Komponenten wie x264, x265, xvid, vid.stab, librubberband) **und**
  `--enable-version3` (Anhebung auf Version 3, u. a. wegen Apache-2.0-
  lizenzierter AMR-Bibliotheken) konfiguriert. Damit gilt für das
  Gesamt-Binary die **GNU General Public License v3**.
- **Quelle Binary:** https://evermeet.cx/ffmpeg/
- **Quellcode:** https://ffmpeg.org/download.html (FFmpeg) sowie die jeweiligen
  Upstreams der einkompilierten Bibliotheken. evermeet.cx bietet selbst
  **keine** Corresponding-Source-Pakete der Builds an.
- **Nutzung durch Hörbuchklöppler:** ausschließlich als separater, unveränderter
  Subprozess (`Process()`), keine Verlinkung gegen FFmpeg-Bibliotheken. Der
  eigene Code bleibt dadurch MIT-lizenziert (bloße Aggregation).
- **Konsequenz für die Verteilung:** Wer die **gebaute App weitergibt**, verteilt
  damit das GPL-3.0-Binary und übernimmt die GPL-Pflichten (Lizenztext beilegen,
  Corresponding Source bereitstellen oder schriftlich anbieten). Da evermeet.cx
  keine Corresponding-Source-Pakete liefert, ist das praktisch kaum sauber
  erfüllbar — **deshalb veröffentlicht dieses Projekt keine gebauten Binaries**,
  sondern nur den Quellcode; jeder baut lokal (`./build.sh`). Der vollständige
  GPL-3.0-Text liegt unter [`licenses/GPL-3.0.txt`](licenses/GPL-3.0.txt) bei.
- **Laufzeit-Fallback:** Fehlt das gebündelte Binary, nutzt die App ein vom
  Nutzer installiertes ffmpeg aus `$PATH`/Homebrew/MacPorts; dabei findet keine
  Verteilung durch dieses Projekt statt.

```
FFmpeg is licensed under the GNU Lesser General Public License (LGPL) version
2.1 or later. However, FFmpeg incorporates several optional parts and
optimizations that are covered by the GNU General Public License (GPL) version
2 or later. If those parts get used the GPL applies to all of FFmpeg.
(Dieser Build: --enable-gpl --enable-version3 → GPL version 3.)

Copyright (c) 2000-2026 the FFmpeg developers
```

---

## MediaInfo (CLI)

- **Lizenz:** BSD-2-Clause
- **Quelle:** https://mediaarea.net/de/MediaInfo · https://github.com/MediaArea/MediaInfo

```
Copyright (c) 2002-2026 MediaArea.net SARL. All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice,
   this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.
```

MediaArea erlaubt für Binary-Weitergaben alternativ den Hinweis:
„This product uses MediaInfo library, Copyright (c) 2002-2026 MediaArea.net SARL.“

---

## swift-argument-parser

- **Lizenz:** Apache-2.0 mit Runtime Library Exception
- **Quelle:** https://github.com/apple/swift-argument-parser
- **Copyright:** © Apple Inc. und die Autoren des Swift-Projekts
- **Verwendung:** nur im CLI-Executable `kloeppler` (statisch gelinkt); die
  GUI-App linkt es nicht. Dank der Runtime Library Exception erfordert die
  Weitergabe des kompilierten CLI keine Attributions-Pflichten nach
  Abschnitt 4(a)/(b)/(d); der Lizenztext ist hier dennoch vollständig
  wiedergegeben.

```
Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/

    TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

    1. Definitions.

      "License" shall mean the terms and conditions for use, reproduction,
      and distribution as defined by Sections 1 through 9 of this document.

      "Licensor" shall mean the copyright owner or entity authorized by
      the copyright owner that is granting the License.

      "Legal Entity" shall mean the union of the acting entity and all
      other entities that control, are controlled by, or are under common
      control with that entity. For the purposes of this definition,
      "control" means (i) the power, direct or indirect, to cause the
      direction or management of such entity, whether by contract or
      otherwise, or (ii) ownership of fifty percent (50%) or more of the
      outstanding shares, or (iii) beneficial ownership of such entity.

      "You" (or "Your") shall mean an individual or Legal Entity
      exercising permissions granted by this License.

      "Source" form shall mean the preferred form for making modifications,
      including but not limited to software source code, documentation
      source, and configuration files.

      "Object" form shall mean any form resulting from mechanical
      transformation or translation of a Source form, including but
      not limited to compiled object code, generated documentation,
      and conversions to other media types.

      "Work" shall mean the work of authorship, whether in Source or
      Object form, made available under the License, as indicated by a
      copyright notice that is included in or attached to the work
      (an example is provided in the Appendix below).

      "Derivative Works" shall mean any work, whether in Source or Object
      form, that is based on (or derived from) the Work and for which the
      editorial revisions, annotations, elaborations, or other modifications
      represent, as a whole, an original work of authorship. For the purposes
      of this License, Derivative Works shall not include works that remain
      separable from, or merely link (or bind by name) to the interfaces of,
      the Work and Derivative Works thereof.

      "Contribution" shall mean any work of authorship, including
      the original version of the Work and any modifications or additions
      to that Work or Derivative Works thereof, that is intentionally
      submitted to Licensor for inclusion in the Work by the copyright owner
      or by an individual or Legal Entity authorized to submit on behalf of
      the copyright owner. For the purposes of this definition, "submitted"
      means any form of electronic, verbal, or written communication sent
      to the Licensor or its representatives, including but not limited to
      communication on electronic mailing lists, source code control systems,
      and issue tracking systems that are managed by, or on behalf of, the
      Licensor for the purpose of discussing and improving the Work, but
      excluding communication that is conspicuously marked or otherwise
      designated in writing by the copyright owner as "Not a Contribution."

      "Contributor" shall mean Licensor and any individual or Legal Entity
      on behalf of whom a Contribution has been received by Licensor and
      subsequently incorporated within the Work.

    2. Grant of Copyright License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      copyright license to reproduce, prepare Derivative Works of,
      publicly display, publicly perform, sublicense, and distribute the
      Work and such Derivative Works in Source or Object form.

    3. Grant of Patent License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      (except as stated in this section) patent license to make, have made,
      use, offer to sell, sell, import, and otherwise transfer the Work,
      where such license applies only to those patent claims licensable
      by such Contributor that are necessarily infringed by their
      Contribution(s) alone or by combination of their Contribution(s)
      with the Work to which such Contribution(s) was submitted. If You
      institute patent litigation against any entity (including a
      cross-claim or counterclaim in a lawsuit) alleging that the Work
      or a Contribution incorporated within the Work constitutes direct
      or contributory patent infringement, then any patent licenses
      granted to You under this License for that Work shall terminate
      as of the date such litigation is filed.

    4. Redistribution. You may reproduce and distribute copies of the
      Work or Derivative Works thereof in any medium, with or without
      modifications, and in Source or Object form, provided that You
      meet the following conditions:

      (a) You must give any other recipients of the Work or
          Derivative Works a copy of this License; and

      (b) You must cause any modified files to carry prominent notices
          stating that You changed the files; and

      (c) You must retain, in the Source form of any Derivative Works
          that You distribute, all copyright, patent, trademark, and
          attribution notices from the Source form of the Work,
          excluding those notices that do not pertain to any part of
          the Derivative Works; and

      (d) If the Work includes a "NOTICE" text file as part of its
          distribution, then any Derivative Works that You distribute must
          include a readable copy of the attribution notices contained
          within such NOTICE file, excluding those notices that do not
          pertain to any part of the Derivative Works, in at least one
          of the following places: within a NOTICE text file distributed
          as part of the Derivative Works; within the Source form or
          documentation, if provided along with the Derivative Works; or,
          within a display generated by the Derivative Works, if and
          wherever such third-party notices normally appear. The contents
          of the NOTICE file are for informational purposes only and
          do not modify the License. You may add Your own attribution
          notices within Derivative Works that You distribute, alongside
          or as an addendum to the NOTICE text from the Work, provided
          that such additional attribution notices cannot be construed
          as modifying the License.

      You may add Your own copyright statement to Your modifications and
      may provide additional or different license terms and conditions
      for use, reproduction, or distribution of Your modifications, or
      for any such Derivative Works as a whole, provided Your use,
      reproduction, and distribution of the Work otherwise complies with
      the conditions stated in this License.

    5. Submission of Contributions. Unless You explicitly state otherwise,
      any Contribution intentionally submitted for inclusion in the Work
      by You to the Licensor shall be under the terms and conditions of
      this License, without any additional terms or conditions.
      Notwithstanding the above, nothing herein shall supersede or modify
      the terms of any separate license agreement you may have executed
      with Licensor regarding such Contributions.

    6. Trademarks. This License does not grant permission to use the trade
      names, trademarks, service marks, or product names of the Licensor,
      except as required for reasonable and customary use in describing the
      origin of the Work and reproducing the content of the NOTICE file.

    7. Disclaimer of Warranty. Unless required by applicable law or
      agreed to in writing, Licensor provides the Work (and each
      Contributor provides its Contributions) on an "AS IS" BASIS,
      WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
      implied, including, without limitation, any warranties or conditions
      of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A
      PARTICULAR PURPOSE. You are solely responsible for determining the
      appropriateness of using or redistributing the Work and assume any
      risks associated with Your exercise of permissions under this License.

    8. Limitation of Liability. In no event and under no legal theory,
      whether in tort (including negligence), contract, or otherwise,
      unless required by applicable law (such as deliberate and grossly
      negligent acts) or agreed to in writing, shall any Contributor be
      liable to You for damages, including any direct, indirect, special,
      incidental, or consequential damages of any character arising as a
      result of this License or out of the use or inability to use the
      Work (including but not limited to damages for loss of goodwill,
      work stoppage, computer failure or malfunction, or any and all
      other commercial damages or losses), even if such Contributor
      has been advised of the possibility of such damages.

    9. Accepting Warranty or Additional Liability. While redistributing
      the Work or Derivative Works thereof, You may choose to offer,
      and charge a fee for, acceptance of support, warranty, indemnity,
      or other liability obligations and/or rights consistent with this
      License. However, in accepting such obligations, You may act only
      on Your own behalf and on Your sole responsibility, not on behalf
      of any other Contributor, and only if You agree to indemnify,
      defend, and hold each Contributor harmless for any liability
      incurred by, or claims asserted against, such Contributor by reason
      of your accepting any such warranty or additional liability.

    END OF TERMS AND CONDITIONS

    APPENDIX: How to apply the Apache License to your work.

      To apply the Apache License to your work, attach the following
      boilerplate notice, with the fields enclosed by brackets "[]"
      replaced with your own identifying information. (Don't include
      the brackets!)  The text should be enclosed in the appropriate
      comment syntax for the file format. We also recommend that a
      file or class name and description of purpose be included on the
      same "printed page" as the copyright notice for easier
      identification within third-party archives.

    Copyright [yyyy] [name of copyright owner]

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.



## Runtime Library Exception to the Apache 2.0 License: ##


    As an exception, if you use this Software to compile your source code and
    portions of this Software are embedded into the binary product as a result,
    you may redistribute such product without providing attribution as would
    otherwise be required by Sections 4(a), 4(b) and 4(d) of the License.
```

---

## Hörprobe („Wunder über Wunder“)

- **Lizenz:** Public Domain (LibriVox)
- **Quelle:** Track 03 aus „Sammlung deutscher Gedichte 018“, LibriVox —
  https://archive.org/details/sammlung_deutscher_gedichte_018_1506_librivox
- **Verwendung:** 49-Sekunden-A/B-Klangbeispiel (`hoerprobe/`), als
  GitHub-Release-Asset vorgesehen, nicht im Repository.

```
LibriVox recordings are in the public domain. No rights reserved.
https://librivox.org/pages/public-domain/
```
