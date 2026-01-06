import json
import os
import sys
import scion_tool

def main():
    try:
        input_data = json.load(sys.stdin)
    except Exception:
        # Non-JSON input, skip
        return

    event = input_data.get("hook_event_name")
    
    state = "IDLE"
    log_msg = f"Event: {event}"

    if event == "SessionStart":
        state = "STARTING"
        log_msg = f"Session started (source: {input_data.get('source')})"
    elif event == "UserPromptSubmit":
        state = "THINKING"
        prompt = input_data.get("prompt", "")
        log_msg = f"User prompt: {prompt[:100]}..." if prompt else "Planning turn"

        if prompt:
            prompt_path = os.path.join(scion_tool.HOME, "prompt.md")
            if not os.path.exists(prompt_path) or os.path.getsize(prompt_path) == 0:
                try:
                    with open(prompt_path, "w") as f:
                        f.write(prompt)
                except Exception as e:
                    scion_tool.log_event("ERROR", f"Failed to save prompt to {prompt_path}: {e}")
    elif event == "PreToolUse":
        tool_name = input_data.get("tool_name")
        state = f"EXECUTING ({tool_name})"
        log_msg = f"Running tool: {tool_name}"
    elif event == "PostToolUse":
        state = "IDLE"
        tool_name = input_data.get("tool_name")
        log_msg = f"Tool {tool_name} completed"
    elif event == "Notification":
        state = "WAITING_FOR_INPUT"
        log_msg = f"Notification: {input_data.get('message')}"
    elif event == "Stop" or event == "SubagentStop":
        state = "IDLE"
        log_msg = "Agent turn completed"
    elif event == "SessionEnd":
        state = "EXITED"
        log_msg = f"Session ended (reason: {input_data.get('reason')})"

    scion_tool.update_status(state)
    scion_tool.log_event(state, log_msg)

if __name__ == "__main__":
    main()
