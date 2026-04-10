# -*- coding: utf-8 -*-
import requests
import json
import time

class ChatClient:
    def __init__(self, api_url, api_key=None, model="gpt-5.4-pro"):
        self.api_url = api_url
        self.api_key = api_key
        self.model = model
        self.session_history = []

    def send_message_stream(self, message):
        payload = {
            "model": self.model,
            "messages": self.session_history + [{"role": "user", "content": message}],
            "stream": True
        }
        headers = {"Content-Type": "application/json"}
        if self.api_key:
            headers["Authorization"] = f"Bearer {self.api_key}"

        print("⏳ 正在发送请求...")
        try:
            with requests.post(self.api_url, headers=headers, data=json.dumps(payload), stream=True, timeout=30) as r:
                r.raise_for_status()
                r.encoding = "utf-8"  # 强制 UTF-8 解码
                print("✅ 请求成功")
                print("🤖 AI: ", end="", flush=True)

                full_reply = ""
                for line in r.iter_lines(decode_unicode=True):
                    if line and line.startswith("data: "):
                        data_str = line[len("data: "):]
                        if data_str.strip() == "[DONE]":
                            break
                        try:
                            data_json = json.loads(data_str)
                            delta = data_json["choices"][0]["delta"].get("content", "")
                            if delta:
                                print(delta, end="", flush=True)
                                full_reply += delta
                        except Exception:
                            continue

                print()  # 换行
                self.session_history.append({"role": "user", "content": message})
                self.session_history.append({"role": "assistant", "content": full_reply})
                return full_reply

        except Exception as e:
            print(f"❌ 错误: {e}")
            return None


if __name__ == "__main__":
    # 替换成你自己的接口地址和 Key
    API_URL = "https://xxx/v1/chat/completions"
    API_KEY = "sk-xxx"

    client = ChatClient(API_URL, API_KEY, model="gpt-5.4-pro")

    print("💬 开始测试 (测试模型gpt-5.4-pro)")
    while True:
        user_input = input("").strip()
        if user_input.lower() in ["exit", "quit"]:
            print("👋 已退出聊天")
            break

        print(f"👤 你: {user_input}")
        client.send_message_stream(user_input)
        time.sleep(1)