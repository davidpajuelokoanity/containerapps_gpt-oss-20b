#!/usr/bin/env python3
"""
chat.py - result-endpoint.md を参照して Ollama と簡易チャットするCLIツール。

deploy.ps1 が result-endpoint.md に書き出した Public_Endpoint の URL・API_Key・
モデル名を読み取り、Ollama の /api/generate エンドポイントへリクエストを送信して
シンプルな対話（チャット）を行う。チャット中に `/pdf <パス>` と入力すると、PDFの各ページを
PNG画像に変換し、Base64エンコードして次のプロンプトと一緒に `images` として送信する。

前提:
- result-endpoint.md が deploy.ps1 実行によって生成済みであること
  （STATUS: Ready の状態、すなわちモデル準備確認まで完了していること）。
- Python 3.8+ で動作する。テキストのみのチャットは標準ライブラリのみで動作する。
- PDF添付を使う場合のみ PyMuPDF が必要（pip install pymupdf）。また、デプロイした
  モデルが画像入力（Vision）に対応している必要がある（gpt-oss はテキスト専用）。

使い方:
    python chat.py
    python chat.py --file path\to\result-endpoint.md
    python chat.py --no-stream
    python chat.py --timeout 180
    python chat.py --dpi 200 --max-pages 5

チャット中のコマンド:
    /pdf <パス>   PDFを画像に変換し、次のプロンプトに添付する
    /clear        添付待ちの画像を破棄する
"""

from __future__ import annotations

import argparse
import base64
import json
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Optional

DEFAULT_RESULT_FILE = "result-endpoint.md"
DEFAULT_TIMEOUT_SECONDS = 120
DEFAULT_PDF_DPI = 150
DEFAULT_PDF_MAX_PAGES = 10

# 認証プロキシ（nginx）は client_max_body_size 未設定のため、既定値1MBを超える
# リクエストボディは413で拒否される。添付画像の合計がこれを超える場合に警告する。
NGINX_DEFAULT_BODY_LIMIT_BYTES = 1024 * 1024

# result-endpoint.md 内の各項目を抽出する正規表現。
# DeploymentMonitor.psm1 の Write-ResultEndpointFile が出力する形式
# （"- URL: <value>" 等）に対応する。
_FIELD_PATTERNS = {
    "url": re.compile(r"^-\s*URL:\s*(.+?)\s*$", re.MULTILINE),
    "api_key": re.compile(r"^-\s*API_KEY:\s*(.+?)\s*$", re.MULTILINE),
    "model": re.compile(r"^-\s*MODEL:\s*(.+?)\s*$", re.MULTILINE),
    "status": re.compile(r"^-\s*STATUS:\s*(.+?)\s*$", re.MULTILINE),
}


class ResultEndpointError(Exception):
    """result-endpoint.md の読み込み・解析に失敗したことを示す例外。"""


class AttachmentError(Exception):
    """PDF添付ファイルの読み込み・画像変換に失敗したことを示す例外。"""


class EndpointInfo:
    """result-endpoint.md から読み取ったデプロイ結果情報。"""

    def __init__(self, url: str, api_key: str, model: str, status: str) -> None:
        self.url = url.rstrip("/")
        self.api_key = api_key
        self.model = model
        self.status = status


def parse_result_endpoint_file(path: Path) -> EndpointInfo:
    """result-endpoint.md を読み込み、URL・API_KEY・MODEL・STATUS を抽出する。

    Args:
        path: result-endpoint.md のパス。

    Returns:
        解析結果を保持する EndpointInfo。

    Raises:
        ResultEndpointError: ファイルが存在しない、または必須項目
            （URL・API_KEY・MODEL）が見つからない場合。
    """
    if not path.is_file():
        raise ResultEndpointError(
            f"{path} が見つかりません。先に deploy.ps1 を実行してデプロイを完了させてください。"
        )

    try:
        content = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise ResultEndpointError(f"{path} の読み込みに失敗しました: {exc}") from exc

    values: dict[str, Optional[str]] = {}
    for key, pattern in _FIELD_PATTERNS.items():
        match = pattern.search(content)
        values[key] = match.group(1).strip() if match else None

    missing = [key for key in ("url", "api_key", "model") if not values.get(key)]
    if missing:
        raise ResultEndpointError(
            f"{path} から必須項目（{', '.join(missing)}）を読み取れませんでした。"
            " deploy.ps1 が正常に完了しているか確認してください。"
        )

    return EndpointInfo(
        url=values["url"],  # type: ignore[arg-type]
        api_key=values["api_key"],  # type: ignore[arg-type]
        model=values["model"],  # type: ignore[arg-type]
        status=values.get("status") or "Unknown",
    )


def pdf_to_base64_images(path: Path, *, dpi: int, max_pages: int) -> tuple[list[str], int]:
    """PDFの各ページをPNG画像にレンダリングし、Base64文字列のリストとして返す。

    Args:
        path: 変換対象のPDFファイルのパス。
        dpi: レンダリング解像度。大きいほど鮮明になるが、リクエストサイズも増える。
        max_pages: 変換する最大ページ数（先頭から数える）。

    Returns:
        (Base64エンコード済みPNGのリスト, PDFの総ページ数) のタプル。

    Raises:
        AttachmentError: PyMuPDF が未インストール、ファイルが存在しない、
            またはPDFとして開けない場合。
    """
    try:
        import pymupdf  # PDF添付時のみ必要なため遅延インポートする
    except ImportError as exc:
        raise AttachmentError(
            "PDFの変換には PyMuPDF が必要です。'pip install pymupdf' を実行してください。"
        ) from exc

    if not path.is_file():
        raise AttachmentError(f"{path} が見つかりません。")

    try:
        with pymupdf.open(path) as doc:
            total_pages = doc.page_count
            if total_pages == 0:
                raise AttachmentError(f"{path} にページがありません。")
            images = [
                base64.b64encode(page.get_pixmap(dpi=dpi).tobytes("png")).decode("ascii")
                for page in doc.pages(0, min(total_pages, max_pages))
            ]
    except RuntimeError as exc:
        # PyMuPDF の FileDataError 等（破損・非PDF・暗号化ファイル）は RuntimeError の派生
        raise AttachmentError(f"{path} をPDFとして開けませんでした: {exc}") from exc

    return images, total_pages


def call_generate(
    endpoint: EndpointInfo,
    prompt: str,
    *,
    stream: bool,
    timeout: int,
    images: Optional[list[str]] = None,
) -> str:
    """Ollamaの /api/generate エンドポイントを呼び出し、応答テキストを返す。

    Args:
        endpoint: 接続先エンドポイント情報。
        prompt: ユーザーが入力したプロンプト文字列。
        stream: Trueの場合、応答をストリーミングで受信しつつ順次表示する
            （ストリーミング表示中も最終的な全文を返す）。
        timeout: HTTPリクエストのタイムアウト秒数。
        images: プロンプトに添付するBase64エンコード済み画像のリスト（任意）。

    Returns:
        モデルが生成した応答テキストの全文。

    Raises:
        urllib.error.URLError: 接続エラー（DNS解決失敗、タイムアウト等）。
        urllib.error.HTTPError: HTTPエラー応答（401: APIキー不一致、5xx等）。
    """
    url = f"{endpoint.url}/api/generate"
    payload = {
        "model": endpoint.model,
        "prompt": prompt,
        "stream": stream,
    }
    if images:
        payload["images"] = images
    body = json.dumps(payload).encode("utf-8")

    request = urllib.request.Request(
        url,
        data=body,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "X-API-Key": endpoint.api_key,
        },
    )

    full_response_parts: list[str] = []

    with urllib.request.urlopen(request, timeout=timeout) as response:
        if not stream:
            raw = response.read().decode("utf-8")
            data = json.loads(raw)
            text = data.get("response", "")
            print(text)
            return text

        # ストリーミングモード: Ollamaは1行に1つのJSONオブジェクトを改行区切りで返す
        # （JSON Lines形式）。行ごとに読み取り、"response"の断片を都度出力する。
        for raw_line in response:
            line = raw_line.decode("utf-8").strip()
            if not line:
                continue
            try:
                chunk = json.loads(line)
            except json.JSONDecodeError:
                continue

            piece = chunk.get("response", "")
            if piece:
                print(piece, end="", flush=True)
                full_response_parts.append(piece)

            if chunk.get("done"):
                break

        print()  # ストリーミング出力の末尾に改行を入れる

    return "".join(full_response_parts)


def run_chat_loop(
    endpoint: EndpointInfo,
    *,
    stream: bool,
    timeout: int,
    pdf_dpi: int = DEFAULT_PDF_DPI,
    pdf_max_pages: int = DEFAULT_PDF_MAX_PAGES,
) -> None:
    """標準入力からプロンプトを読み込み、応答を表示し続けるチャットループ。

    'exit'、'quit'、または空入力でループを終了する。Ctrl+C（KeyboardInterrupt）
    やEOF（Ctrl+Dなど）でも安全に終了する。

    '/pdf <パス>' でPDFを画像に変換して添付待ちにし、次のプロンプト送信時に一緒に送る。
    送信に成功した時点で添付待ちの画像はクリアされる（失敗時は保持され、再送できる）。
    """
    pending_images: list[str] = []

    print(f"接続先: {endpoint.url}")
    print(f"モデル: {endpoint.model}")
    if endpoint.status.lower() != "ready":
        print(
            f"警告: result-endpoint.md の STATUS が '{endpoint.status}' です"
            "（モデル準備が完了していない可能性があります）。"
        )
    print("プロンプトを入力してください。終了するには 'exit' または 'quit' と入力してください。")
    print("PDFを添付するには '/pdf <パス>'、添付を取り消すには '/clear' と入力してください。")
    print("-" * 60)

    while True:
        try:
            prompt = input("You> ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            print("チャットを終了します。")
            break

        if not prompt:
            continue

        if prompt.lower() in ("exit", "quit"):
            print("チャットを終了します。")
            break

        if prompt.lower() == "/clear":
            pending_images.clear()
            print("添付待ちの画像を破棄しました。")
            continue

        if prompt.lower().startswith("/pdf"):
            # エクスプローラーからのドラッグ&ドロップで付く引用符を取り除く
            pdf_arg = prompt[len("/pdf"):].strip().strip('"').strip("'")
            if not pdf_arg:
                print("使い方: /pdf <PDFファイルのパス>")
                continue
            try:
                images, total_pages = pdf_to_base64_images(
                    Path(pdf_arg), dpi=pdf_dpi, max_pages=pdf_max_pages
                )
            except AttachmentError as exc:
                print(f"エラー: {exc}", file=sys.stderr)
                continue

            pending_images.extend(images)
            print(f"{len(images)}/{total_pages} ページを画像として添付しました。", end="")
            if total_pages > len(images):
                print(f"（--max-pages {pdf_max_pages} により先頭のみ）", end="")
            print(" 次のプロンプトと一緒に送信します。")

            total_bytes = sum(len(image) for image in pending_images)
            if total_bytes > NGINX_DEFAULT_BODY_LIMIT_BYTES:
                print(
                    f"警告: 添付画像の合計が約 {total_bytes // 1024} KB です。認証プロキシ（nginx）の"
                    " 既定上限1MBを超えるため、413エラーになる可能性があります。"
                    " --dpi や --max-pages を下げるか、nginx の client_max_body_size を引き上げてください。",
                    file=sys.stderr,
                )
            continue

        print("Bot> ", end="" if stream else "\n", flush=True)

        try:
            call_generate(
                endpoint, prompt, stream=stream, timeout=timeout, images=pending_images or None
            )
            pending_images.clear()
        except urllib.error.HTTPError as exc:
            if exc.code == 401:
                print(
                    "エラー: 認証に失敗しました（401）。"
                    " result-endpoint.md のAPI_Keyが正しいか確認してください。",
                    file=sys.stderr,
                )
            elif exc.code == 413:
                print(
                    "エラー: リクエストが大きすぎます（413）。添付画像は保持されています。"
                    " '/clear' 後に --dpi や --max-pages を下げて再添付するか、"
                    " nginx の client_max_body_size を引き上げてください。",
                    file=sys.stderr,
                )
            else:
                print(f"エラー: HTTPエラーが発生しました（{exc.code}）: {exc.reason}", file=sys.stderr)
        except urllib.error.URLError as exc:
            print(
                f"エラー: エンドポイントへの接続に失敗しました: {exc.reason}."
                " Container Appがスケールダウンしている場合、初回リクエストの応答に"
                " 時間がかかることがあります。しばらく待って再試行してください。",
                file=sys.stderr,
            )
        except json.JSONDecodeError as exc:
            print(f"エラー: 応答の解析に失敗しました: {exc}", file=sys.stderr)

        print()


def build_arg_parser() -> argparse.ArgumentParser:
    """コマンドライン引数パーサーを構築する。"""
    parser = argparse.ArgumentParser(
        description=(
            "result-endpoint.md を参照して、Ollama と簡易チャットを行うCLIツール。"
            " チャット中に '/pdf <パス>' でPDFを画像として添付できる（Vision対応モデルが必要）。"
        )
    )
    parser.add_argument(
        "--file",
        default=DEFAULT_RESULT_FILE,
        help=f"result-endpoint.md のパス（既定値: {DEFAULT_RESULT_FILE}）",
    )
    parser.add_argument(
        "--no-stream",
        action="store_true",
        help="ストリーミング応答を無効化し、応答全文が完成してから一度に表示する。",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=DEFAULT_TIMEOUT_SECONDS,
        help=f"HTTPリクエストのタイムアウト秒数（既定値: {DEFAULT_TIMEOUT_SECONDS}）",
    )
    parser.add_argument(
        "--dpi",
        type=int,
        default=DEFAULT_PDF_DPI,
        help=f"PDFを画像に変換する際の解像度（既定値: {DEFAULT_PDF_DPI}）",
    )
    parser.add_argument(
        "--max-pages",
        type=int,
        default=DEFAULT_PDF_MAX_PAGES,
        help=f"1つのPDFから添付する最大ページ数（既定値: {DEFAULT_PDF_MAX_PAGES}）",
    )
    return parser


def main(argv: Optional[list[str]] = None) -> int:
    """エントリーポイント。終了コードを返す（0: 正常終了, 1: エラー）。"""
    args = build_arg_parser().parse_args(argv)

    try:
        endpoint = parse_result_endpoint_file(Path(args.file))
    except ResultEndpointError as exc:
        print(f"エラー: {exc}", file=sys.stderr)
        return 1

    run_chat_loop(
        endpoint,
        stream=not args.no_stream,
        timeout=args.timeout,
        pdf_dpi=args.dpi,
        pdf_max_pages=args.max_pages,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
