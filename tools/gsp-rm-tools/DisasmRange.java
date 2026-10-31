import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Instruction;
public class DisasmRange extends GhidraScript {
    public void run() throws Exception {
        String[] a = getScriptArgs()[0].split(",");
        Address addr = currentProgram.getAddressFactory().getDefaultAddressSpace().getAddress(a[0].trim());
        int n = Integer.parseInt(a[1].trim());
        for (int i = 0; i < n; i++) {
            Instruction insn = currentProgram.getListing().getInstructionAt(addr);
            if (insn == null) { disassemble(addr); insn = currentProgram.getListing().getInstructionAt(addr); }
            if (insn == null) { println("  <no insn at " + addr + ">"); break; }
            println("  " + addr + ": " + insn.toString());
            addr = insn.getMaxAddress().add(1);
        }
    }
}
