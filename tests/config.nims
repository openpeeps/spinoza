switch("path", "$projectDir/../src")
# Same dev libvirt bindings the src/ build uses (see src/spinoza.nims).
# The released libvirt package lacks toXML().
switch("path", "/Users/georgelemon/Development/bindings/libvirt/src")
switch("passL", "-L/opt/local/lib")
switch("passL", "-lvirt-qemu")
switch("passL", "-lssh2")
switch("passC", "-I/opt/local/include")