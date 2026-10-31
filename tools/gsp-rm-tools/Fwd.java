import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Instruction;
public class Fwd extends GhidraScript {
    public void run() throws Exception {
        String arg = getScriptArgs()[0];
        int n = Integer.parseInt(getScriptArgs()[1]);
        for (String s : arg.split(",")) {
            Address a = currentProgram.getAddressFactory().getDefaultAddressSpace().getAddress(s.trim());
            if (getInstructionAt(a) == null) disassemble(a);
            Instruction cur = getInstructionAt(a);
            StringBuilder sb = new StringBuilder(s);
            for (int i = 0; i < n && cur != null; i++) { sb.append(" | ").append(cur.getAddress()).append(": ").append(cur.toString()); cur = cur.getNext(); }
            println(sb.toString());
        }
    }
}
