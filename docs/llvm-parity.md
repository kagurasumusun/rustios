# Swift の LLVM を共有しても、どちらのコンパイラも機能を失わないこと

rustios の目標は「**1 つの LLVM** から、iOS で動く Swift コンパイラと iOS で動く
Rust コンパイラを作る」ことです（[llvm-sharing.md](llvm-sharing.md)）。
この文書は、そのときに **Swift 側の LLVM ビルド設定を Rust 側の要求に合わせる**
（＝ Rust が自前で LLVM をビルドした場合と機能差を出さない）ために何を揃えたか、
揃えられないものをどう扱ったかを記録します。

対象は LLVM の**ビルド構成**と、Rust のビルド構成のうち「成果物の性能・機能に
効くもの」です。`macOS` はビルド用ホストで、成果物は iOS のみです。

---

## 1. 共有 LLVM が Rust に提供しなければならないもの

rustc は LLVM を「リンクするライブラリ」としてだけでなく、**ビルド時に道具として**
使います。足りないと、ビルドが失敗するか、静かに機能が落ちます。

| 必要なもの | 誰が使うか | 無いとどうなるか | rustios の対応 |
| --- | --- | --- | --- |
| iOS の静的ライブラリ一式 (`lib/*.a`) | rustc のリンク（`rustc_llvm`） | リンクできない | Swift の iOS ビルド成果物をそのまま `SwiftLLVM/ios/lib` に置く |
| ヘッダ (`include/`, 生成物含む) | `rustc_llvm` の C++ ラッパーのコンパイル | ビルドできない | `llvm-config --includedir` と `llvm-config.h` を確認 |
| `llvm-config`（ホストで動く） | bootstrap と `rustc_llvm` | ビルドできない | `Scripts/llvm-config-shim.py` が再配置可能な POSIX sh を生成 |
| **`LLVM_TOOLS` の 14 個** (`llvm-ar`, `llvm-objcopy`, `llvm-profdata`, `llc`, `opt`, …) | bootstrap が `lib/rustlib/<host>/bin` に導入し、端末上の rustc が `llvm-ar`/`rust-objcopy` として使う | `lib/rustlib/<host>/bin` が空になり、端末で静的ライブラリを作れない・`-C strip` が効かない | Swift 側のインストールで 14 個 + `llvm-ranlib` を両ツリー（macOS/iOS）に入れる。Rust 側は揃っている時だけ `llvm-tools = true` |
| `compiler-rt` のソース | `compiler-builtins` の C 実装 (`compiler-builtins-c`) | 純 Rust の組み込み実装にフォールバックし、`memcpy` などが遅くなる（公式ツールチェーンとの差） | 共有 LLVM と**同じ llvm-project コミット**から `compiler-rt/lib/builtins` を取る |
| `FileCheck`（ビルド機用） | `x.py test` の codegen テスト | `codegen-tests = true` にできない | macOS ツリーにあれば入れて `codegen-tests = true`、無ければ false とレポート |
| コンポーネント情報 (`llvm-config --components`) | `rustc_llvm` が必須コンポーネントの有無を検査 | ビルドが panic | シムがホストの答えをそのまま返す |

`LLVM_TOOLS` の一覧は `src/bootstrap/src/lib.rs` の定数で、bootstrap は
`Sysroot` ステップで `llvm-config --bindir` の隣からこれをコピーします
（`compile.rs`）。外部 LLVM の場合は「`llvm-config` と同じディレクトリ」を
使う実装なので、`SwiftLLVM/{macosx,ios}/bin` に置けばそのまま入ります。

> 以前の rustios は 5 個 (`llvm-ar`/`llvm-nm`/`llvm-ranlib`/`llvm-objcopy`/
> `llvm-strip`) しか入れておらず、`llvm-tools = false` でこの仕組みごと
> 切っていました。結果として配布物に `lib/rustlib/aarch64-apple-ios/bin` が
> 無く、**端末上の rustc は `ar` を要求する**状態でした。現在は 14 個を
> 入れ、`llvm-tools = true` で公式と同じ配置にしています。

### 1.1 共有 LLVM の `bin/` は「自動では」作られない

プリセットは LLVM-On-iOS 由来の `build-toolchain-only=1` を引き継いでおり、
これは Swift の `utils/build_swift` が LLVM を

```
-DLLVM_BUILD_TOOLS=NO            # ツールはターゲットを作るが all では作らない
-DLLVM_INSTALL_TOOLCHAIN_ONLY=YES
-DLLVM_INCLUDE_UTILS=NO
-DLLVM_TOOL_LLVM_AR_BUILD=NO     # llvm-ar は「そもそも構成しない」
```

で configure するということです（`products/llvm.py`）。ライブラリは全部できて
`llvm-config` もできるのに、**`bin/` にはツールが 1 つも残らない**。
run 40285701494 はまさにこれで、20 バックエンド・199 ライブラリの完全な
ツリーを 4 時間 50 分かけて作りながら `swift LLVM: 0/15 rustc LLVM tools` に
なり、Rust 側は `llvm-tools = false` に落ちていました。

対処（`Scripts/build-swift-toolchain.sh` の `build_llvm_tools`）:

* `build-script` が終わったあと、既存の build tree に対して
  `cmake -DLLVM_BUILD_TOOLS=ON -DLLVM_TOOL_<NAME>_BUILD=ON …` で再 configure し、
  `ninja llvm-ar llvm-ranlib … llc opt` で 15 個だけリンクします。
  ライブラリのフラグは変えないので、**既にビルド済みのものは再ビルドされません**
  （追加は数分）。
* macOS ツリーだけ `-DLLVM_INCLUDE_UTILS=ON -DLLVM_BUILD_UTILS=ON` を足して
  `FileCheck not count` も作ります（`codegen-tests` 用。参照ビルドは
  `LLVM_INSTALL_UTILS=ON` でこれらを持つ）。
* `LLVM_TOOL_<NAME>_BUILD` は `create_llvm_tool_options`（`AddLLVM.cmake`）が
  `llvm/tools/*` を走査して作るキャッシュ変数なので、数時間前に configure された
  ツリーでも後から ON にできます。`LLVM_BUILD_TOOLS=NO` は
  「`EXCLUDE_FROM_ALL` にする」だけなので、明示的に `ninja` すれば作れます。
* 失敗しても **致命的にしません**（5 時間のビルドを捨てない）。その場合は
  `warn` とレポート行が残り、Rust 側は `llvm-tools = false` として理由を出します。

---

## 2. LLVM の CMake 構成: Rust の参照ビルドとの比較

「Rust の参照ビルド」= rust-lang/rust 1.94.0 の
`src/bootstrap/src/core/build_steps/llvm.rs` が `x.py build` で渡す `-D` の集合
（`bootstrap.toml` の既定値、対象は `aarch64-apple-ios`）。
「Swift の参照ビルド」= このプリセットから `-DLLVM_ENABLE_*` を外したもの、
つまり Swift の既定（`utils/build_swift` の `--llvm-targets-to-build` 既定値と
LLVM 自身の CMake 既定値）。

| 設定 | Rust の参照ビルド | 共有 LLVM (Swift) | 判定 |
| --- | --- | --- | --- |
| ビルド種別 | Release (`llvm.optimize=true`) | `release` | 同一 |
| アサーション | OFF (`llvm.assertions=false`) | `-DLLVM_ENABLE_ASSERTIONS=OFF` | 同一 |
| 例外 (EH) | 未指定 → CMake 既定 OFF | `-DLLVM_ENABLE_EH=OFF` | 同一 |
| RTTI | 未指定 → CMake 既定 OFF | `-DLLVM_ENABLE_RTTI=ON` | **共有側が上位互換**（§4.2） |
| スレッド | 未指定 → 既定 ON | `-DLLVM_ENABLE_THREADS=ON` | 同一 |
| zlib（iOS ツリー） | `*-apple-{ios,tvos,watchos,visionos}` では OFF を明示 | OFF（ツリーごとに seed、§2.1） | 同一 |
| zlib（macOS ツリー） | ホスト向けは ON | ON（ツリーごとに seed、§2.1） | 同一 |
| zstd | `llvm.libzstd` 既定 **false** → `-DLLVM_ENABLE_ZSTD=OFF` | `-DLLVM_ENABLE_ZSTD=OFF` | 同一 |
| terminfo | 未指定 → 見つかれば ON | `-DLLVM_ENABLE_TERMINFO=ON` | 同一 |
| バックトレース | 未指定 → 既定 ON | `-DLLVM_ENABLE_BACKTRACES=ON` | 同一 |
| `llvm_unreachable` の最適化 | `-DLLVM_UNREACHABLE_OPTIMIZE=OFF` | 同じ | 同一 |
| LLVM のツール | `LLVM_BUILD_TOOLS` 既定 ON、`LLVM_INSTALL_UTILS=ON` | `build-toolchain-only=1` で **OFF** | ビルド後に 15 個だけリンクして揃える（§1.1） |
| LLVM の utils (FileCheck) | `LLVM_INCLUDE_UTILS` 既定 ON | OFF | macOS ツリーのみ ON にして FileCheck を作る |
| プラグイン | apple モバイルでは OFF を明示 | 未指定 → CMake 既定（Darwin は `LLVM_ENABLE_PIC` に従い ON） | **共有側が上位互換**（§4.3） |
| LLVM 自体の LTO | `llvm.thin-lto` 既定 false | 未指定 | 同一 |
| **バックエンド** | `llvm.targets` 既定 **`all`** | `llvm-targets-to-build=AArch64` | **意図的な縮小**（§4.5） |
| テスト | `llvm.tests=false` → OFF | `llvm-include-tests=0` | 同一 |
| libxml2 | OFF を明示 | 未指定（見つかれば ON） | 共有側が上位互換（rustc は使わない） |
| Z3 | OFF | 未指定 | 実質同一 |
| `LLVM_INSTALL_UTILS` | ON | 使わない（§1 の 15 個を自前で配置） | 同一（配置は §1） |

CMake のオプションは `Scripts/swift-ios-toolchain-presets.ini`
（`extra-cmake-options` と `llvm-targets-to-build`）にあります。

### 2.1 ツリーごとに違う値: zlib

`extra-cmake-options` は **macOS 用と iOS 用の両ツリーに同じ値**が渡ります
（`utils/build-script` の cmake 呼び出しで、Swift 自身の `-D` より後ろに
`${EXTRA_CMAKE_OPTIONS[@]}` が並ぶ）。ところが zlib だけは、rust の参照ビルドで
**ツリーによって値が違います**（ホストは ON、`*-apple-ios` は OFF。`llvm.rs`:
「Zlib fails to link properly」）。そこで `build-swift-toolchain.sh` の
`seed_llvm_trees` が、`build-script` を呼ぶ前に各ツリーの `CMakeCache.txt` に
値を書きます:

- まだ configure されていないツリー: 1 行の `CMakeCache.txt`
  （`LLVM_ENABLE_ZLIB:BOOL=OFF` など）を置く。cmake はコマンドラインに無い
  キャッシュ値をそのまま使うので、configure はこの値で走ります。
- 既に configure 済みのツリー: `cmake -DLLVM_ENABLE_ZLIB:BOOL=… .` で同じ値を
  設定してから `build-script` に渡す（`reconfigure` はこの値を保持します）。

したがって preset の `extra-cmake-options` に zlib は書かず（書くと両ツリーを
上書きしてしまう）、`install_llvm` が両ツリーの `llvm/Config/llvm-config.h` と
`llvm-config --system-libs` で値を確認します（違えば `die`）。両方の値は
`SwiftLLVM/llvm-project.txt` にも記録され、レポートに出ます。

> 以前の版のこの文書は zstd を「差」と書いていましたが、それは誤りでした。
> `llvm.libzstd` の既定は `false`（`config.rs`: `llvm_libzstd.unwrap_or(false)`）
> で、rust も `LLVM_ENABLE_ZSTD=OFF` を渡します（`llvm.rs`: 885–889）。

## 3. Rust 側のビルド構成: 公式配布ビルドとの比較

公式バイナリの構成は rust-lang/rust の CI 定義
（`src/ci/github-actions/jobs.yml` の `--set rust.lto=thin --set
rust.codegen-units=1`、`src/ci/run.sh` の `--set rust.codegen-units-std=1`）が
正です。

| 設定 | 公式配布ビルド | 以前の rustios | 現在の rustios | 影響 |
| --- | --- | --- | --- | --- |
| `rust.lto` | `thin` | 既定 (`thin-local`) | **`thin`** | rustc 本体の最適化。以前は公式より遅い rustc だった |
| `rust.codegen-units` | `1` | `16` | **`1`** | 同上 |
| `rust.codegen-units-std` | `1` | 未設定 | **`1`** | std の最適化 |
| `build.optimized-compiler-builtins` | `true`（既定） | **`false`** | **`true`** | `memcpy`/`__divti3` などの組み込み実装。以前は純 Rust 版 |
| `rust.llvm-tools` | `true`（既定） | **`false`** | **`true`** | `lib/rustlib/<host>/bin` の有無 |
| `rust.codegen-tests` | `true`（既定） | **`false`** | FileCheck があれば `true` | `x.py test` の codegen テストのみ |
| `build.sanitizers` | 既定 `false`（dist ジョブが明示的に有効化） | `false` | `false` | §4 |
| `build.extended` | dist は `true` | `false` | `false` | 成果物に影響しない（必要なステップを明示指定している） |
| `build.submodules` | 自動 | `false` | `false` | `compiler-rt` を自前で置くため。§1 |

`lto=thin` と `codegen-units=1` は**ビルド時間**と引き換えです。3 コアの
macOS ランナーで stage1+stage2 が 35 分程度だったところから増えますが、
ジョブ上限は 6 時間なので吸収できます。成果物の性能を公式と揃えるための
コストとして受け入れています。

`RUST_LTO` / `RUST_CODEGEN_UNITS` で上書きできます（速くビルドしたいとき用）。

---

## 4. 残る差と、その影響の限定

残っている差は 2 種類だけです。

1. **共有ツリーのほうが上位互換**なもの（§4.2 RTTI、§4.3 プラグイン、
   libxml2）。どちらも rustc が使わない機能が増えているだけで、失うものが
   ありません。
2. **バックエンドを AArch64 だけに絞ったこと**（§4.5）。これは利用者の判断で
   入れたスコープの縮小で、参照ビルド（`llvm.targets=all`）に対する能力差が
   1 つだけ残ります: この rustc は **他のターゲット向けにコードを生成できない**。

### 4.1 zlib（差ではなくなった）

- rust の参照ビルドは、ホスト向け LLVM を zlib **ON**、`*-apple-ios` 向けを
  **OFF** で作ります（`llvm.rs`: 「Zlib fails to link properly」）。
- 以前は `--extra-cmake-options` が両ツリーに同じ値を渡すため「両方 OFF」を
  選び、macOS ツリー（＝ビルド機で動く stage1 rustc がリンクする LLVM）だけが
  参照ビルドより少ない状態でした。
- 現在は `seed_llvm_trees` が各ツリーの CMake キャッシュに別々の値を入れるので
  （§2.1）、**iOS ツリー OFF / macOS ツリー ON** と、参照ビルドと同じ値に
  なっています。`install_llvm` は `llvm-config.h` の値と `-lz` の有無で両方を
  検証し、`SwiftLLVM/llvm-project.txt` とレポートに両方の値を残します。

### 4.2 RTTI（共有側が上位互換）

Swift のビルドは `LLVM_ENABLE_RTTI=ON` を要求します（Swift 自身が使う）。
Rust の参照ビルドは OFF ですが、`rustc_llvm` の C++ ラッパーは RTTI を
一切使いません（`compiler/rustc_llvm/llvm-wrapper/` に `RTTI`/`rtti` の
出現なし、`build.rs` も `--has-rtti` を問い合わせない）。差は
`llvm-config --cxxflags` に `-fno-rtti` が付くかどうかだけで、生成コードには
影響しません。ON は「Rust 側が余分に得る」方向なので、1% の損失になりません。

### 4.3 プラグイン（共有側が上位互換）

rust は apple モバイル向けに `LLVM_ENABLE_PLUGINS=OFF` を明示します
（`-bundle` が CFLAGS に混ざるのを避けるため）。共有ツリーは未指定なので
CMake 既定（Darwin では `LLVM_ENABLE_PIC` に従い ON）です。
`rustc` は LLVM のパスプラグインを `dlopen` しないため、**観測できる差は
ありません**。このツリーで macOS/iOS 両方のビルドが通ることは既に実績があります
（`docs/llvm-sharing.md` の CI 履歴）。

### 4.4 sanitizer (`build.sanitizers = false`)

- bootstrap の既定値は `false` です（`config.rs`: `sanitizers:
  build_sanitizers.unwrap_or(false)`）。公式の dist ジョブが明示的に有効化して
  いるだけで、`x.py` の既定からの逸脱ではありません。
- 有効にすると `-Zsanitizer=…` 用のランタイムを std に同梱しますが、
  `-Z` は stable チャネルでは使えず、iOS の ASan ランタイムは Xcode が
  提供します。**観測できる差はありません**。

### 4.5 バックエンドを AArch64 だけにしたこと（意図的なスコープ判断）

- 共有 LLVM は `llvm-targets-to-build=AArch64` です。Swift も rustc も
  arm64 上で動き、rustc のターゲットは `aarch64-apple-ios` だけなので、
  他の 19 バックエンドはビルド時間と成果物サイズにしかなりません。
- **失うもの**: この rustc は `aarch64-apple-ios` 以外のターゲット向けに
  コードを生成できません（例: 端末上から `--target wasm32-unknown-unknown` や
  `--target x86_64-unknown-linux-gnu` を使うことはできません）。参照ビルド
  （`llvm.targets=all`）に対する唯一の実質的な能力差で、
  「iOS 向けに Swift と Rust をビルドする」という目的の範囲では差になりません。
  元に戻すときは preset の `llvm-targets-to-build` を広げるだけです
  （`docs/llvm-sharing.md` の CI 履歴に、`all` と `AArch64;ARM;X86` の実測が
  あります）。
- `AArch64` だけで通るようになった理由（run 40470888454 で確定）: compiler-rt の
  builtins プロジェクトが、Darwin では既定で **ベアメタル ARM** の
  `macho_embedded_<arch>`（armv6m … armv8.1m.main、32bit）も作ります。
  build-script は Embedded Swift 用に
  `-DBUILTINS_<host-triple>_COMPILER_RT_FORCE_BUILD_BAREMETAL_MACHO_BUILTINS_ARCHS=…`
  を渡すため（`utils/swift_build_support/.../products/llvm.py`）、
  `llvm-targets-to-build=AArch64` でも 32bit ARM のコード生成が必要になり、
  ARM バックエンドのオプション `-arm-add-build-attributes` が無いと失敗します。
  preset の `build-embedded-stdlib=0` がこの 1 変数を止めます。
  - `-DCOMPILER_RT_BUILD_BUILTINS:BOOL=OFF` では止まりません。
    `llvm/runtimes/CMakeLists.txt` は `builtins-<host-triple>` という**別プロジェクト**を
    立てて `compiler-rt/lib/builtins` を直接 configure するので、この変数を読みません
    （sanitizer ランタイム側の builtins を止めるだけです）。
  - 止まるのはベアメタル ARM の 7 アーキだけです。clang とリンカが実際に使う
    `libclang_rt.builtins_arm64_osx.a` / `…_ios.a` は SDK から導出される別経路
    (`builtin-config-ix.cmake`) で作られ続けます（同じ run のログに
    `ios supported builtin arches: arm64;arm64e` があります）。したがって
    `llvm-install-components` の `builtins` はそのまま残しています。
  - 失うのは **AArch64 しか出力できないコンパイラでは元々ターゲットにできない**
    Embedded Swift のベアメタル ARM 対応だけです。compiler-rt のそれ以外
    （sanitizer ランタイム）は従来通りです。
  - この食い違いを再発させないため、`build-swift-toolchain.sh` の `install_llvm` は
    **両ツリーの `llvm-config --targets-built` が preset と一致しなければ die**
    します（以前は Rust 側で警告するだけでした）。
- ビルド時間はこの変更で短くなります（実測は §5）。
- 6 時間のジョブ上限に対する保険として、`.github/workflows/build-rust-ios.yml`
  はビルドとパッケージを 2 ジョブに分けたままにしています。
  - `swift`: ビルドしてキャッシュ（`swift-built-*`）に保存するだけ;
  - `swift_package`: 同じキーでキャッシュを復元し、パッケージ・検証・
    アップロードを行う。
- キャッシュは `restore-keys` の前方一致でも復元されるため、**古いプリセットで
  ビルドしたツリーを掴まないように**、ツリー自身が
  `SwiftLLVM/llvm-project.txt` に `targets=`（と `targets_built=`）を記録し、
  復元直後にプリセットの値と比較します（違えばビルドし直す）。
- それでもビルドジョブが 6 時間を超えるようなら、次の選択肢は
  バックエンドを減らすことですが、そのときはこの文書とレポートに
  「どのバックエンドを落としたか」を必ず書きます（黙って減らさない）。

## 5. CI でどう確認しているか（実測）

`artifacts/REPORT.txt`（PR コメントに出る）に、次の行が出ます。以下は
**run 40402352677（`llvm-targets-to-build=all`、2026-10-27）の実出力**です。

Swift 側:

```
swift LLVM (macosx): built 16 LLVM tool target(s)
swift LLVM (ios): built 15 LLVM tool target(s)
swift LLVM (macosx/bin): 15/15 rustc LLVM tools installed
swift LLVM (macosx/bin): FileCheck present
swift LLVM (ios/bin): 15/15 rustc LLVM tools installed
swift LLVM: 15/15 rustc LLVM tools present and iOS/arm64
swift LLVM: 20 backends (AArch64;AMDGPU;ARM;AVR;BPF;Hexagon;Lanai;LoongArch;Mips;MSP430;NVPTX;PowerPC;RISCV;Sparc;SPIRV;SystemZ;VE;WebAssembly;X86;XCore)
swift LLVM: backends match the preset (llvm-targets-to-build=all)
swift LLVM: 265 static libraries (ios/lib)
```

Rust 側:

```
shared LLVM backends: 20 (...) = llvm-targets-to-build=all
shared LLVM preflight: 21.0.0, 199 libraries, iOS slice confirmed (3 sampled)
configure: llvm-tools = true (14 tools from the shared LLVM, macOS and iOS)
configure: optimized-compiler-builtins = true (compiler-rt 903b9faaa)
configure: codegen-tests = true (FileCheck from the shared LLVM)
llvm-tools: 14/14 tools in lib/rustlib/aarch64-apple-ios/bin (rust-objcopy present)
compiler_builtins: compiler-rt C intrinsics built (out/libcompiler-rt.a, 145 objects)
compiler_builtins: build script emitted the optimized-c cfg
RustToolchain: llvm-tools 380M (15 files in lib/rustlib/aarch64-apple-ios/bin)
```

成果物（同じ run）:

| 成果物 | サイズ | 前回（`AArch64;ARM;X86`、llvm-tools 無し） |
| --- | --- | --- |
| `SwiftLLVM-…-21.1.6.tar.xz` | 240 M | 96 M |
| `SwiftToolchain-…-6.4.0.tar.xz` | 544 M | 480 M |
| `LLVM.xcframework-…` | 53 M | 44 M |
| `RustToolchain-…-1.94.0.tar.xz` | 112 M | 35 M（llvm-tools の 380M 展開分を含む） |
| `RustStd-…-1.94.0.tar.xz` | 352 M | 256 M（compiler-rt の C 実装を含む） |
| `Rust.xcframework-…` | 192 M | 96 M（同じく compiler-rt を含む） |

- ツール（`llvm-tools`）が有効になるのは、**macOS と iOS の両ツリーに
  14 個すべてが揃っているときだけ**です。1 つでも欠ければ
  `llvm-tools = false` に落として理由をレポートに残します（6 時間かけた
  ビルドを、道具が 1 つ無いせいで落とさないため）。要求される一覧は
  bootstrap のソース（`const LLVM_TOOLS`）から読むので、Rust を上げて
  一覧が変わっても configure の時点で分かります。
- バックエンドは 2 か所で突き合わせます。
  - Swift 側（`install_llvm`）: **両方のビルドツリー**の
    `llvm-config --targets-built` がプリセットと一致しなければ **die**。
    何もインストールする前に落ちるので、古い preset で configure された
    ツリーをそのまま出荷しません。一致すれば
    `swift LLVM: backends macOS [...] / iOS [...] = llvm-targets-to-build=...`
    がレポートに出ます。
  - Rust 側（`preflight`）: `AArch64` が無ければ即エラー、記録された
    `targets=` がプリセットと違えば
    `shared LLVM backends: **N** ... - not full parity` を出します
    （アーティファクト経由で古いツリーを掴んだ場合の保険）。
  CI のキャッシュ復元も `llvm-project.txt` の `targets=` と
  `targets_built=` を見て、古い preset のツリーは捨ててビルドし直します。
- ビルド時間（実測）: Swift のビルド 2 h 25 m + 梱包 25 m + Rust 1 h 25 m、
  合計 3 h 36 m（run 40402352677）。`all` でも 6 時間のジョブ上限に対して
  余裕があり、ジョブ分割はそのまま維持します（別の run では 5 h 55 m に
  達したため）。

## 6. この文書の範囲外

- Swift ツールチェーンの中身（stdlib の同梱範囲）は
  [llvm-sharing.md](llvm-sharing.md) §0 の成果物構成の話で、ここでは扱いません。
- `Rust.xcframework` の静的化と C API は
  [llvm-sharing.md](llvm-sharing.md) §6 で扱います（C API は rustc 本体に
  コンパイルする方式で、LLVM の設定とは独立です）。
- Swift 側のビルド時間そのものの短縮（ccache、分散ビルドなど）。
