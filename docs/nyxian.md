# nyxian での使い方

rustios は [emexlab/nyxian](https://github.com/emexlab/nyxian) に組み込んで
使うために調整されています。nyxian は stock iOS(18.0〜27.x)上で動く完全
オンデバイス IDE で、emexlab/LLVM-On-iOS をサブモジュールとして組み込み、
Swift / C / Objective-C / C++ のオンデバイスコンパイルを行います。rustios は
その消費インターフェースをそのまま守り、Rust の対応物を追加します。

## nyxian が LLVM-On-iOS をどう消費しているか(調査結果)

nyxian がピン留めしているコミット `5c2e215a`(master HEAD、
「feat: added swift 6.4.0 support」)で調査しました。

1. **nyxian のルート Makefile**:

   ```make
   Frameworks/CoreCompiler/CoreCompilerSupportLibs:
       cd LLVM-On-iOS; $(MAKE)
       rm -rf Frameworks/CoreCompiler/CoreCompilerSupportLibs/
       cp -r LLVM-On-iOS/CoreCompilerSupportLibs Frameworks/CoreCompiler/CoreCompilerSupportLibs/
       cp -r LLVM-On-iOS/LLVM.xcframework Frameworks/CoreCompiler/CoreCompilerSupportLibs/LLVM.xcframework
   ```

   サブモジュールの既定 `make` がリポジトリルートに残す 2 つのディレクトリ
   (`CoreCompilerSupportLibs/` = `lib_Compiler*.dylib` のフラット置き、
   `LLVM.xcframework/` = `llvm.a` + Headers)を nyxian が `cp -r` します。

2. **Xcode プロジェクト(project.pbxproj)**:
   * Copy Files フェーズが `lib_Compiler*.dylib` 各々と `LLVM.xcframework` を
     CodeSignOnCopy でアプリに埋め込む。
   * `Shared` フォルダが folder reference としてアプリの Resources に入る
     (`Shared/SwiftToolchain` もこれで同梱される)。

3. **CCDriver.cpp**(Frameworks/CoreCompiler/Tools/): `LLVM.xcframework` の
   静的 `llvm.a` をリンクし、`swift::driver::Driver` C++ API でコンパイラを
   プロセス内駆動。dylib は実行時にロード。

4. **install-nyxian**: サブモジュール側の
   `make install-nyxian-swift-toolchain` → スクリプトの `install-nyxian` が
   `SwiftToolchain.zip` を `${NYXIAN_SHARED_DIR:-../Shared}` に展開し、
   `Shared/SwiftToolchain/usr/...` になる。ツールチェーン本体(swiftc 等)は
   Shared リソースとしてアプリに同梱され、ゲストプロセスから実行される。

5. `.gitignore` は `Frameworks/CoreCompiler/CoreCompilerSupportLibs/` を無視
   (ビルド生成物はコミットしない)。

## rustios の互換インターフェース

`make`(既定の all)は LLVM-On-iOS と同名・同内容の Swift 成果物に加え Rust
対応物をビルドし、**リポジトリルート**に次のディレクトリを置きます
(`nyxian-swift-dirs` / `nyxian-rust-dirs`、`work/` のステージングからの
コピーで、内容は成果物 tar.xz と同一です):

| ルートディレクトリ | 中身 | nyxian での用途 |
| --- | --- | --- |
| `CoreCompilerSupportLibs/` | `lib_Compiler*.dylib` | 既存レシピのまま `cp -r` → 埋め込み |
| `LLVM.xcframework/` | `llvm.a` + Headers | 既存レシピのまま `cp -r` → 埋め込み + 静的リンク |
| `RustSupportLibs/` | `librustc_driver-*.dylib`、`libstd-*.dylib`、`codegen-backends/` | CoreCompilerSupportLibs の Rust 版 |
| `Rust.xcframework/` | `rust.a` + `Headers/rustios.h` | LLVM.xcframework の Rust 版(C API) |

Shared リソース(デバイス側で実行するツールチェーン本体):

| ターゲット | インストール先 | 中身 |
| --- | --- | --- |
| `make install-nyxian-swift-toolchain` | `../Shared/SwiftToolchain/usr` | LLVM-On-iOS の install-nyxian と同一 |
| `make install-nyxian-rust-toolchain` | `../Shared/RustToolchain/usr` | コンパイラ + std を統合した単一 sysroot(`bin/rustc`、`lib/rustlib/aarch64-apple-ios/{lib,codegen-backends}` 等) |
| `make install-nyxian` | 上記両方 | |

`NYXIAN_SHARED_DIR` 環境変数で Shared の場所を上書きできます(既定
`../Shared` = rustios が nyxian 内にサブモジュール/隣接チェックアウトとして
あるときの親の Shared)。スクリプトのサブコマンドも LLVM-On-iOS と同名です:
`install-nyxian`、`verify-host`(= `verify` のエイリアス)。

Rust の std はコンパイラと別成果物(`RustStd.tar.xz`)ですが、
install-nyxian は両者をマージして 1 ツリーでインストールします
(SwiftToolchain と同じ「1 ディレクトリで完結」の形)。マージせずに別々に
使いたい場合は `RustStd` の README(成果物内)を参照してください。

## nyxian 側の接続手順

サブモジュール(URL)を rustios にすれば、**Swift の既存フローはそのまま**
動きます(既定 `make` が同じ 2 ディレクトリをルートに残すため)。
Swift だけが欲しい場合は `make swift nyxian-swift-dirs` で Rust ビルドを
スキップできます。

Rust 対応を追加するなら、nyxian の Makefile に:

```make
cp -r <rustios>/RustSupportLibs  Frameworks/CoreCompiler/RustSupportLibs
cp -r <rustios>/Rust.xcframework Frameworks/CoreCompiler/RustSupportLibs/Rust.xcframework
```

Xcode プロジェクト側:

* Copy Files(CodeSignOnCopy)に `RustSupportLibs` の
  `librustc_driver-*.dylib` と `libstd-*.dylib` を追加。
* `Rust.xcframework` をリンクし、`rustios.h` の C API でコンパイラを
  プロセス内駆動(Swift で CCDriver.cpp が `swift::driver::Driver` を使う
  のと同じ位置付け。ヘッダは `Rust.xcframework` の Headers にも
  `RustToolchain/usr/include` にも入っています)。
* `Shared/RustToolchain` は既存の Shared folder reference で自動的にアプリに
  同梱される。ゲストプロセスからは `usr/bin/rustc` をそのまま実行できます
  (std 統合済みなので追加設定は不要)。

## LLVM-On-iOS(pinned 版)との差分

* 既定 `make` は Rust もビルドします(LLVM は 1 回だけビルドし両コンパイラ
  で共有 — 全体像は [llvm-sharing.md](llvm-sharing.md))。
* `llvm-targets-to-build=AArch64`(彼らは全ターゲット): 6 時間の CI 上限に
  収めるため。これでスキップされるのは compiler-rt の macho_embedded
  ベアメタル builtins(どの成果物も使わない)だけで、仕組みは
  [parity.md](parity.md) §3 に記載。
* ZLIB/TERMINFO OFF: `llvm.a` 静的リンク時にシステムライブラリ依存を
  増やさないため(parity.md §3)。
* lld の Mach-O パッチ(「apple lies, lld works fine for MachO」)は
  彼らの pinned 版では Makefile の perl で適用されますが、rustios では
  fetch 時にスクリプトが適用します(意味は同一、冪等)。
* ルートディレクトリは `work/` のステージングからのコピーです
  (彼らはビルドレシピが直接ルートに生成)。名前・内容は同一。

## 検証

CI(`.github/workflows/build-rust-ios.yml`)は両ジョブの末尾でこの
インターフェースを検証します:

* `make nyxian-swift-dirs` / `make nyxian-rust-dirs` → ルートディレクトリと
  重要ファイル(`lib_Compiler*.dylib`、`LLVM.xcframework/Info.plist`、
  `librustc_driver-*.dylib`、`Rust.xcframework/Info.plist`)の存在。
* 偽の `Shared/` ディレクトリ(`NYXIAN_SHARED_DIR`)に対する
  install-nyxian のスモークテスト → `Shared/SwiftToolchain/usr/bin/swiftc` と
  `Shared/RustToolchain/usr/bin/rustc` + マージ済み std rlib の存在。
