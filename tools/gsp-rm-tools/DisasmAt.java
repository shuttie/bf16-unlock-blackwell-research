import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Instruction;
public class DisasmAt extends GhidraScript {
    public void run() throws Exception {
        for (String s : getScriptArgs()[0].split(",")) {
            Address addr = currentProgram.getAddressFactory().getDefaultAddressSpace().getAddress(s.trim());
            println("=== " + addr);
            for (int i = 0; i < 14; i++) {
                Instruction insn = currentProgram.getListing().getInstructionAt(addr);
                if (insn == null) { disassemble(addr); insn = currentProgram.getListing().getInstructionAt(addr); }
                if (insn == null) { println("  no insn at " + addr); break; }
                println("  " + addr + ": " + insn.toString());
                addr = insn.getMaxAddress().add(1);
            }
        }
    }
}
