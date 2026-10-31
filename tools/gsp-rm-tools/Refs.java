import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.symbol.Reference;
import ghidra.program.model.symbol.ReferenceIterator;
public class Refs extends GhidraScript {
    public void run() throws Exception {
        for (String s : getScriptArgs()[0].split(",")) {
            Address a = currentProgram.getAddressFactory().getDefaultAddressSpace().getAddress(s.trim());
            Reference[] refs = getReferencesTo(a);
            println("refs to " + a + ": " + refs.length);
            for (Reference r : refs) println("  from " + r.getFromAddress() + " " + r.getReferenceType());
            ReferenceIterator it = currentProgram.getReferenceManager().getReferenceIterator(a);
            int n = 0;
            while (it.hasNext() && n < 20) { Reference r = it.next(); println("  iter " + r.getFromAddress() + " -> " + r.getToAddress()); n++; }
        }
    }
}
