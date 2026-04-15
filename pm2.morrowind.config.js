module.exports = {
  apps: [
    {
      name: 'mw-bridge',
      namespace: 'morrowind',
      script: 'python3',
      args: '/home/nemoclaw/morrowind-ai/python/main.py',
      cwd: '/home/nemoclaw/morrowind-ai/python',
      interpreter: 'none',
      env: {
        PYTHONPATH: '/home/nemoclaw/morrowind-ai/python'
      },
      log_file: '/home/nemoclaw/morrowind-ai/logs/mw-bridge.log',
      error_file: '/home/nemoclaw/morrowind-ai/logs/mw-bridge.err',
      restart_delay: 3000,
      max_restarts: 5,
      watch: false,
      autorestart: true
    },
    {
      name: 'mw-pixel',
      namespace: 'morrowind',
      script: 'python3',
      args: [
        '-c',
        'import asyncio; from agents.pixel_agent import PixelAgent; import yaml; cfg=yaml.safe_load(open("config.yaml")); a=PixelAgent(cfg); asyncio.run(a.run())'
      ],
      cwd: '/home/nemoclaw/morrowind-ai/python',
      interpreter: 'none',
      env: { PYTHONPATH: '/home/nemoclaw/morrowind-ai/python' },
      log_file: '/home/nemoclaw/morrowind-ai/logs/mw-pixel.log',
      error_file: '/home/nemoclaw/morrowind-ai/logs/mw-pixel.err',
      restart_delay: 5000,
      max_restarts: 10,
      watch: false,
      autorestart: true,
      enabled: false  // enable when streaming
    },
    {
      name: 'mw-chat',
      namespace: 'morrowind',
      script: 'python3',
      args: [
        '-c',
        'import asyncio; from stream.youtube_chat import YouTubeChatListener; from stream.chat_commands import ChatCommandHandler; import yaml; cfg=yaml.safe_load(open("config.yaml")); h=ChatCommandHandler(cfg); l=YouTubeChatListener(cfg,h); asyncio.run(l.start(cfg["stream"]["youtube_video_id"]))'
      ],
      cwd: '/home/nemoclaw/morrowind-ai/python',
      interpreter: 'none',
      env: { PYTHONPATH: '/home/nemoclaw/morrowind-ai/python' },
      log_file: '/home/nemoclaw/morrowind-ai/logs/mw-chat.log',
      error_file: '/home/nemoclaw/morrowind-ai/logs/mw-chat.err',
      restart_delay: 5000,
      max_restarts: 10,
      watch: false,
      autorestart: true,
      enabled: false  // enable when streaming with video_id set
    }
  ]
};
