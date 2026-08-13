#define GLFW_INCLUDE_NONE
#include <GLFW/glfw3.h>

// Optional IME positioning (not in stable GLFW 3.4–3.5 headers). When a build
// exports glfwSetIMECursorPos, glfwSetIMEWindowPos, or glfwSetInputMethodCursorPos,
// translate-c will expose them and platform/glfw.zig will call them from setImePosition.
#if defined(GLFW_VERSION_MAJOR) && defined(GLFW_VERSION_MINOR) && 0
GLFWAPI void glfwSetIMECursorPos(struct GLFWwindow* window, double xpos, double ypos);
GLFWAPI void glfwSetIMEWindowPos(struct GLFWwindow* window, int xpos, int ypos);
GLFWAPI void glfwSetInputMethodCursorPos(struct GLFWwindow* window, double xpos, double ypos);
#endif
