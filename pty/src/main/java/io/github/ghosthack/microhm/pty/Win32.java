package io.github.ghosthack.microhm.pty;

import java.lang.foreign.Arena;
import java.lang.foreign.FunctionDescriptor;
import java.lang.foreign.Linker;
import java.lang.foreign.MemoryLayout;
import java.lang.foreign.MemorySegment;
import java.lang.foreign.StructLayout;
import java.lang.foreign.SymbolLookup;
import java.lang.invoke.MethodHandle;
import java.lang.invoke.VarHandle;

import static java.lang.foreign.ValueLayout.ADDRESS;
import static java.lang.foreign.ValueLayout.JAVA_INT;
import static java.lang.foreign.ValueLayout.JAVA_LONG;
import static java.lang.foreign.ValueLayout.JAVA_SHORT;

/**
 * The kernel32 calls a ConPTY needs, bound once through the FFM API (Windows 10 1809+,
 * x64 and arm64: every struct offset below is the 64-bit layout). Calls that report
 * failure through {@code GetLastError} capture it.
 */
final class Win32 {

    /** {@code COORD}: two shorts, passed by value. */
    static final StructLayout COORD = MemoryLayout.structLayout(JAVA_SHORT.withName("X"), JAVA_SHORT.withName("Y"));

    static final int STARTF_USESTDHANDLES = 0x100;
    static final int EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
    static final int CREATE_UNICODE_ENVIRONMENT = 0x00000400;
    static final int CREATE_SUSPENDED = 0x00000004;
    static final long PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = 0x00020016L;
    static final int JOB_OBJECT_EXTENDED_LIMIT_INFORMATION = 9;
    static final int JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000;
    static final int INFINITE = 0xFFFFFFFF;
    static final int ERROR_BROKEN_PIPE = 109;
    static final int ERROR_INSUFFICIENT_BUFFER = 122;

    /** {@code STARTUPINFOEXW}: {@code STARTUPINFOW} (104 bytes) + the attribute list pointer. */
    static final long STARTUPINFOEX_BYTES = 112;
    static final long STARTUPINFO_FLAGS_OFFSET = 60;
    static final long STARTUPINFO_ATTRIBUTES_OFFSET = 104;
    /** {@code PROCESS_INFORMATION}: hProcess, hThread, dwProcessId, dwThreadId. */
    static final long PROCESS_INFORMATION_BYTES = 24;
    /** {@code JOBOBJECT_EXTENDED_LIMIT_INFORMATION}; LimitFlags sits in its basic part. */
    static final long JOB_LIMIT_BYTES = 144;
    static final long JOB_LIMIT_FLAGS_OFFSET = 16;

    private static final Linker LINKER = Linker.nativeLinker();
    private static final SymbolLookup KERNEL32 = SymbolLookup.libraryLookup("kernel32", Arena.global());
    private static final StructLayout CALL_STATE = Linker.Option.captureStateLayout();
    private static final VarHandle LAST_ERROR =
            CALL_STATE.varHandle(MemoryLayout.PathElement.groupElement("GetLastError"));
    private static final Linker.Option CAPTURE = Linker.Option.captureCallState("GetLastError");

    static final MethodHandle CREATE_PIPE = errorCall("CreatePipe",
            FunctionDescriptor.of(JAVA_INT, ADDRESS, ADDRESS, ADDRESS, JAVA_INT));
    /** Returns an HRESULT (0 = S_OK). */
    static final MethodHandle CREATE_PSEUDO_CONSOLE = call("CreatePseudoConsole",
            FunctionDescriptor.of(JAVA_INT, COORD, ADDRESS, ADDRESS, JAVA_INT, ADDRESS));
    static final MethodHandle RESIZE_PSEUDO_CONSOLE = call("ResizePseudoConsole",
            FunctionDescriptor.of(JAVA_INT, ADDRESS, COORD));
    static final MethodHandle CLOSE_PSEUDO_CONSOLE = call("ClosePseudoConsole", FunctionDescriptor.ofVoid(ADDRESS));
    static final MethodHandle INITIALIZE_ATTRIBUTE_LIST = errorCall("InitializeProcThreadAttributeList",
            FunctionDescriptor.of(JAVA_INT, ADDRESS, JAVA_INT, JAVA_INT, ADDRESS));
    static final MethodHandle UPDATE_ATTRIBUTE = errorCall("UpdateProcThreadAttribute",
            FunctionDescriptor.of(JAVA_INT, ADDRESS, JAVA_INT, JAVA_LONG, ADDRESS, JAVA_LONG, ADDRESS, ADDRESS));
    static final MethodHandle DELETE_ATTRIBUTE_LIST = call("DeleteProcThreadAttributeList",
            FunctionDescriptor.ofVoid(ADDRESS));
    static final MethodHandle CREATE_PROCESS = errorCall("CreateProcessW", FunctionDescriptor.of(JAVA_INT,
            ADDRESS, ADDRESS, ADDRESS, ADDRESS, JAVA_INT, JAVA_INT, ADDRESS, ADDRESS, ADDRESS, ADDRESS));
    static final MethodHandle CREATE_JOB = errorCall("CreateJobObjectW",
            FunctionDescriptor.of(ADDRESS, ADDRESS, ADDRESS));
    static final MethodHandle SET_JOB_INFORMATION = errorCall("SetInformationJobObject",
            FunctionDescriptor.of(JAVA_INT, ADDRESS, JAVA_INT, ADDRESS, JAVA_INT));
    static final MethodHandle ASSIGN_TO_JOB = errorCall("AssignProcessToJobObject",
            FunctionDescriptor.of(JAVA_INT, ADDRESS, ADDRESS));
    static final MethodHandle TERMINATE_JOB = errorCall("TerminateJobObject",
            FunctionDescriptor.of(JAVA_INT, ADDRESS, JAVA_INT));
    static final MethodHandle RESUME_THREAD = errorCall("ResumeThread", FunctionDescriptor.of(JAVA_INT, ADDRESS));
    static final MethodHandle WAIT_FOR_SINGLE_OBJECT = errorCall("WaitForSingleObject",
            FunctionDescriptor.of(JAVA_INT, ADDRESS, JAVA_INT));
    static final MethodHandle GET_EXIT_CODE_PROCESS = errorCall("GetExitCodeProcess",
            FunctionDescriptor.of(JAVA_INT, ADDRESS, ADDRESS));
    /** {@code SetConsoleCtrlHandler(NULL, FALSE)}: this process stops ignoring Ctrl+C — an
     * attribute children inherit. */
    static final MethodHandle SET_CONSOLE_CTRL_HANDLER = errorCall("SetConsoleCtrlHandler",
            FunctionDescriptor.of(JAVA_INT, ADDRESS, JAVA_INT));
    static final MethodHandle CLOSE_HANDLE = errorCall("CloseHandle", FunctionDescriptor.of(JAVA_INT, ADDRESS));
    static final MethodHandle READ_FILE = errorCall("ReadFile",
            FunctionDescriptor.of(JAVA_INT, ADDRESS, ADDRESS, JAVA_INT, ADDRESS, ADDRESS));
    static final MethodHandle WRITE_FILE = errorCall("WriteFile",
            FunctionDescriptor.of(JAVA_INT, ADDRESS, ADDRESS, JAVA_INT, ADDRESS, ADDRESS));

    private Win32() {
    }

    /** A segment to pass as the leading call-state argument of a capturing handle. */
    static MemorySegment callState(Arena arena) {
        return arena.allocate(CALL_STATE);
    }

    static int lastError(MemorySegment callState) {
        return (int) LAST_ERROR.get(callState, 0L);
    }

    /** {@code COORD} for columns × rows, clamped to what a short holds. */
    static MemorySegment coord(Arena arena, int columns, int rows) {
        MemorySegment c = arena.allocate(COORD);
        c.set(JAVA_SHORT, 0, (short) Math.clamp(columns, 1, Short.MAX_VALUE));
        c.set(JAVA_SHORT, 2, (short) Math.clamp(rows, 1, Short.MAX_VALUE));
        return c;
    }

    static void closeHandle(MemorySegment handle) {
        if (handle == null || handle.address() == 0) {
            return;
        }
        try (Arena arena = Arena.ofConfined()) {
            int ignored = (int) CLOSE_HANDLE.invokeExact(callState(arena), handle);
        } catch (Throwable ignored) {
            // Nothing useful to do: the handle is abandoned either way.
        }
    }

    private static MethodHandle call(String name, FunctionDescriptor descriptor) {
        return LINKER.downcallHandle(KERNEL32.findOrThrow(name), descriptor);
    }

    private static MethodHandle errorCall(String name, FunctionDescriptor descriptor) {
        return LINKER.downcallHandle(KERNEL32.findOrThrow(name), descriptor, CAPTURE);
    }
}
