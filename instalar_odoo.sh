#!/bin/bash

###############################################################################
#                       BY Wanderlei - Boot Software                          #
# Instalação do Odoo com HTTPS e PostgreSQL configurado para conexões externas#
###############################################################################

# Salvar diretório atual
INSTALL_DIR=$(pwd)

# Perguntar se o usuário deseja desinstalar tudo antes de proceder
read -p "Deseja desinstalar o Odoo e todas as dependências antes de instalar novamente? (s/n): " UNINSTALL_CHOICE

# Solicitar informações do usuário
read -p "Digite a versão do Odoo que deseja instalar (exemplo: 18.0): " OE_VERSION
read -p "Digite o endereço de email para o Certbot/Let's Encrypt: " EMAIL
read -p "Digite a senha para o usuário PostgreSQL 'odoo': " POSTGRES_PASSWORD
read -p "Digite a porta para o Odoo (se vazio, usará '8069' como padrão): " ODOO_PORT
ODOO_PORT=${ODOO_PORT:-8069}
# Solicitar o IP para liberação de acesso ao PostgreSQL
read -p "Digite o IP que terá acesso ao banco de dados PostgreSQL (por exemplo: 192.168.0.100): " ALLOWED_IP 

if [[ "$UNINSTALL_CHOICE" == "s" || "$UNINSTALL_CHOICE" == "S" ]]; then
    # Desinstalar o Odoo e todas as dependências
    echo "Desinstalando o Odoo e todas as dependências..."

    # Parar o serviço do Odoo se estiver rodando
    sudo systemctl stop odoo
    sudo systemctl disable odoo

    # Remover o código-fonte do Odoo
    sudo rm -rf $INSTALL_DIR/odoo
    sudo rm -rf /var/lib/odoo
    sudo rm -rf /var/log/odoo
    sudo rm -f /etc/odoo.conf
    sudo rm -f /etc/systemd/system/odoo.service

    # Remover o PostgreSQL e pacotes instalados
    sudo -u postgres dropdb odoo
    sudo -u postgres dropuser odoo
    sudo apt-get remove --purge postgresql postgresql-contrib -y
    sudo apt-get autoremove --purge -y
    sudo apt-get clean
    
    sudo rm -f /etc/nginx/sites-available/$DOMAIN_NAME

    echo "Desinstalação concluída!"
fi

# Atualizar a lista de pacotes e o sistema
sudo apt update && sudo apt upgrade -y

# Instalar dependências do sistema
sudo apt install -y python3 python3-pip python3-venv build-essential wget git \
                    libxslt-dev libzip-dev libldap2-dev libsasl2-dev \
                    libssl-dev libjpeg-dev libpq-dev libffi-dev \
                    nodejs npm nginx certbot python3-certbot-nginx ufw

# Instalar o PostgreSQL
sudo apt install -y postgresql postgresql-contrib

# # Configurar o PostgreSQL para o usuário do Odoo e permitir conexões externas
# Garantir que o usuário odoo existe
sudo -u postgres psql -c "DO \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'odoo') THEN CREATE USER odoo WITH CREATEDB LOGIN SUPERUSER PASSWORD '${POSTGRES_PASSWORD}'; END IF; END \$\$;"

# Permitir conexões externas no PostgreSQL
sudo sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/g" /etc/postgresql/*/main/postgresql.conf

# Garantir que as linhas de configuração do PostgreSQL para o IP liberado estejam presentes
grep -qxF "local   all             odoo                                    md5" /etc/postgresql/*/main/pg_hba.conf || echo "local   all             odoo                                    md5" | sudo tee -a /etc/postgresql/*/main/pg_hba.conf
grep -qxF "host    all             all             $ALLOWED_IP/32           md5" /etc/postgresql/*/main/pg_hba.conf || echo "host    all             all             $ALLOWED_IP/32           md5" | sudo tee -a /etc/postgresql/*/main/pg_hba.conf

# Reiniciar o PostgreSQL
sudo systemctl restart postgresql

# Atualizar regras de firewall para permitir o acesso ao PostgreSQL
sudo ufw allow from $ALLOWED_IP to any port 5432 proto tcp

# Configurar firewall e liberar portas necessárias
# Instalar o UFW se não estiver presente
if ! command -v ufw &> /dev/null; then
    echo "UFW não encontrado. Instalando UFW..."
    sudo apt install ufw -y
fi

# Configurar firewall e liberar portas necessárias, incluindo SSH (porta 22)
sudo ufw allow 22/tcp      # Garante que conexões SSH não serão interrompidas
sudo ufw allow 80,443,8069,5432/tcp  # Libera portas para HTTP, HTTPS, Odoo, PostgreSQL

# Ativar o firewall sem interromper conexões SSH
echo "Ativando UFW com as portas necessárias..."
sudo ufw --force enable
# Verificar se as portas estão ativas no UFW
echo "Verificando portas no UFW..."
for port in 22 80 443 $ODOO_PORT 5432; do
    sudo ufw status | grep -qw "$port" && echo "Porta $port está aberta" || echo "Porta $port não está aberta"
done

# Baixar o código-fonte do Odoo no diretório atual
cd $INSTALL_DIR
sudo git clone --depth 1 --branch $OE_VERSION https://www.github.com/odoo/odoo --single-branch

# Criar ambiente virtual para o Python
cd $INSTALL_DIR/odoo
python3 -m venv odoo-venv
source odoo-venv/bin/activate

# Instalar dependências do Odoo
pip install wheel
pip install -r requirements.txt

# Instalar dependências do frontend
sudo npm install -g rtlcss less less-plugin-clean-css

# Configurar permissões
sudo chown -R $USER:$USER $INSTALL_DIR/odoo

# Limpar o arquivo de configuração se ele já existir
ODOO_CONF="/etc/odoo.conf"
if [ -f "$ODOO_CONF" ]; then
    sudo rm "$ODOO_CONF"
    echo "Arquivo de configuração $ODOO_CONF removido para limpeza."
fi

# Criar um novo arquivo de configuração básico para o Odoo
echo -e "\
[options]\n\
addons_path = /home/ubuntu/odoo/odoo/addons\n\
data_dir = /var/lib/odoo\n\
db_host = False\n\
db_port = False\n\
db_user = odoo\n\
db_password = ${POSTGRES_PASSWORD}\n\
logfile = /var/log/odoo/odoo.log\n\
" | sudo tee "$ODOO_CONF" > /dev/null

# Definir permissões no arquivo de configuração
sudo chmod 640 "$ODOO_CONF"
sudo chown $USER:$USER "$ODOO_CONF"

# Criar diretório de logs
sudo mkdir /var/log/odoo
sudo chown $USER:$USER /var/log/odoo

# Criar o serviço do Odoo
echo -e "\
[Unit]\n\
Description=Odoo\n\
Documentation=http://www.odoo.com\n\
[Service]\n\
User=$USER\n\
Group=$USER\n\
ExecStart=$INSTALL_DIR/odoo/odoo-venv/bin/python3 $INSTALL_DIR/odoo/odoo-bin -c /etc/odoo.conf\n\
[Install]\n\
WantedBy=multi-user.target\n\
" | sudo tee /etc/systemd/system/odoo.service

# Ativar e iniciar o serviço do Odoo
sudo systemctl daemon-reload
sudo systemctl enable --now odoo

# Configurar o Nginx para o domínio
NGINX_CONFIG_PATH="/etc/nginx/sites-available/$DOMAIN_NAME"

if [ -f "$NGINX_CONFIG_PATH" ]; then
    echo "Arquivo de configuração do Nginx já existe. Sobrescrevendo..."
    sudo rm -f "$NGINX_CONFIG_PATH"
fi

# Criar configuração do Nginx
sudo bash -c "cat << 'EOF' > $NGINX_CONFIG_PATH
server {
    listen 80;
    server_name $DOMAIN_NAME;

    location / {
        proxy_pass http://127.0.0.1:$ODOO_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location ~* \.js$ {
        add_header Content-Type application/javascript;
    }

    location ~* \.css$ {
        add_header Content-Type text/css;
    }

    location ~* \.png$ {
        add_header Content-Type image/png;
    }

    location ~* \.jpg$ {
        add_header Content-Type image/jpeg;
    }

    location ~* \.jpeg$ {
        add_header Content-Type image/jpeg;
    }

    location ~* \.gif$ {
        add_header Content-Type image/gif;
    }
}
EOF"

# Habilitar a configuração do Nginx e reiniciar o serviço
sudo ln -s $NGINX_CONFIG_PATH /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl restart nginx

# Obter certificado SSL com Let's Encrypt
sudo certbot --nginx -d $DOMAIN_NAME --email $EMAIL --agree-tos --non-interactive

# Reiniciar Nginx
sudo systemctl restart nginx

echo "Instalação concluída! O Odoo está acessível em https://$DOMAIN_NAME"
