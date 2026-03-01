sudo kubectl apply -f ds389-configmap.yaml -f ds389-statefulset.yaml -f ds389-headless.yaml -n dev

dsconf localhost backend create --suffix "dc=oneinchmarket,dc=co,dc=kr" --be-name "userRoot" --create-suffix
ldapsearch -x -H ldap://localhost:3389 -D "cn=Directory Manager" -w 'DirectoryManagerPassword' -b "" -s base namingContexts

# ou=users,dc=oneinchmarket,dc=co,dc=kr
# ou=groups,dc=oneinchmarket,dc=co,dc=kr

# ds389 컨테이너에서
cat > /tmp/ou-base.ldif <<'LDIF'
dn: ou=users,dc=oneinchmarket,dc=co,dc=kr
objectClass: top
objectClass: organizationalUnit
ou: users

dn: ou=groups,dc=oneinchmarket,dc=co,dc=kr
objectClass: top
objectClass: organizationalUnit
ou: groups
LDIF

ldapadd -H ldap://localhost:3389   -D "cn=Directory Manager" -W   -f /tmp/ou-base.ldif

# 결과확인
ldapsearch -H ldap://localhost:3389   -D "cn=Directory Manager" -W   -b "ou=users,dc=oneinchmarket,dc=co,dc=kr" -s base   "(objectClass=*)" dn objectClass ou

# 등록된 사용자 확인
ldapsearch -H ldap://localhost:3389   -D "cn=Directory Manager" -W   -b "ou=users,dc=oneinchmarket,dc=co,dc=kr" -s one "(objectClass=*)" dn uid

# 등록된 그룹 확인
ldapsearch -H ldap://localhost:3389   -D "cn=Directory Manager" -W   -b "ou=groups,dc=oneinchmarket,dc=co,dc=kr" -s one "(objectClass=*)" dn cn

# UID와 GID는 겹치지 않아야 하며, 겹쳤다면 GID를 수정.
# 그 후에는 groups의 Edit Members에도 출력됨.