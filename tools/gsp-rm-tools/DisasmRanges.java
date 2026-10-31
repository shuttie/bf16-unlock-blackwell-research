// Disassemble multiple ranges: arg0 = "start:n;start:n;..."
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Instruction;

public class DisasmRanges extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] ranges = getScriptArgs()[0].split(";");
        for (String r : ranges) {
            String[] a = r.split(":");
            Address addr = currentProgram.getAddressFactory().getDefaultAddressSpace().getAddress(a[0].trim());
            int n = Integer.parseInt(a[1].trim());
            println("### RANGE " + a[0] + " n=" + n);
            for (int i = 0; i < n; i++) {
                Instruction insn = currentProgram.getListing().getInstructionAt(addr);
                if (insn == null) {
                    disassemble(addr);
                    insn = currentProgram.getListing().getInstructionAt(addr);
                }
                if (insn == null) { println("  " + addr + ": <undef>"); addr = addr.add(2); continue; }
                println("  " + addr + ": " + insn.toString());
                addr = insn.getMaxAddress().add(1);
            }
        }
    }
}
