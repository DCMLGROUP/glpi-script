#!/bin/bash

# Source variables file
if [ -f "variables.sh" ]; then
    source variables.sh
else
    echo "Le fichier variables.sh est manquant. Veuillez le créer avec les variables requises."
    exit 1
fi

# Fonction pour détecter la distribution
detect_distribution() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$NAME
        VERSION=$VERSION_ID
    else
        echo "Impossible de détecter la distribution"
        exit 1
    fi
}

# Installation des dépendances selon la distribution
install_dependencies() {
    case $OS in
        "Debian GNU/Linux"|"Ubuntu")
            apt update
            apt install -y apache2 mariadb-server php php-mysql php-xml php-ldap \
                         php-curl php-gd php-intl php-zip php-bz2 php-mbstring \
                         php-imap php-apcu php-xmlrpc php-cas php-exif php-opcache
            ;;
        "Fedora")
            dnf update -y
            dnf install -y httpd mariadb-server php php-mysql php-xml php-ldap \
                         php-curl php-gd php-intl php-zip php-bz2 php-mbstring \
                         php-imap php-apcu php-xmlrpc php-cas php-exif php-opcache
            systemctl enable httpd
            systemctl start httpd
            # Configuration SELinux pour GLPI
            setsebool -P httpd_can_network_connect on
            setsebool -P httpd_can_network_connect_db on
            setsebool -P httpd_can_sendmail on
            semanage fcontext -a -t httpd_sys_rw_content_t "/var/www/glpi(/.*)?"
            semanage fcontext -a -t httpd_sys_rw_content_t "/var/lib/glpi(/.*)?"
            semanage fcontext -a -t httpd_sys_rw_content_t "/etc/glpi(/.*)?"
            restorecon -R /var/www/glpi
            restorecon -R /var/lib/glpi
            restorecon -R /etc/glpi
            ;;
        "Raspbian GNU/Linux")
            apt update
            apt install -y apache2 mariadb-server php php-mysql php-xml php-ldap \
                         php-curl php-gd php-intl php-zip php-bz2 php-mbstring \
                         php-imap php-apcu php-xmlrpc php-cas php-exif php-opcache
            ;;
        *)
            echo "Distribution non supportée"
            exit 1
            ;;
    esac
}

# Installation de GLPI
install_glpi() {
    # Téléchargement de la dernière version de GLPI
    wget https://github.com/glpi-project/glpi/releases/download/$GLPI_VERSION/glpi-$GLPI_VERSION.tgz
    tar xzf glpi-$GLPI_VERSION.tgz -C /var/www/
    rm glpi-$GLPI_VERSION.tgz
    
    # Configuration des permissions
    chown -R www-data:www-data /var/www/glpi
    chmod -R 755 /var/www/glpi

    # Création des répertoires sécurisés hors du dossier web
    mkdir -p /var/lib/glpi/files
    mkdir -p /etc/glpi/config
    
    # Vérification de l'existence des répertoires source avant le déplacement
    if [ -d "/var/www/glpi/files" ] && [ "$(ls -A /var/www/glpi/files)" ]; then
        mv /var/www/glpi/files/* /var/lib/glpi/files/
    fi
    
    if [ -d "/var/www/glpi/config" ] && [ "$(ls -A /var/www/glpi/config)" ]; then
        mv /var/www/glpi/config/* /etc/glpi/config/
    fi
    
    rm -rf /var/www/glpi/files
    rm -rf /var/www/glpi/config
    ln -s /var/lib/glpi/files /var/www/glpi/files
    ln -s /etc/glpi/config /var/www/glpi/config
    chown -R www-data:www-data /var/lib/glpi /etc/glpi
    chmod -R 750 /var/lib/glpi /etc/glpi

    # Sécurisation du dossier racine
    cat > /var/www/glpi/.htaccess <<EOF
<IfModule mod_rewrite.c>
    RewriteEngine On
    RewriteCond %{REQUEST_URI} !^/public/
    RewriteCond %{REQUEST_URI} !^/index.php
    RewriteCond %{REQUEST_URI} !^/api.php
    RewriteCond %{REQUEST_URI} !^/apirest.php
    RewriteRule ^(.*)$ /public/$1 [L]
</IfModule>
EOF
}

# Configuration de la base de données
configure_database() {
    systemctl start mariadb
    systemctl enable mariadb

    # Configuration des fuseaux horaires MySQL
    mysql_tzinfo_to_sql /usr/share/zoneinfo | mysql -u root mysql

    # Suppression de la base et de l'utilisateur s'ils existent déjà
    mysql -e "DROP DATABASE IF EXISTS $DB_NAME;"
    mysql -e "DROP USER IF EXISTS '$DB_USER'@'localhost';"
    
    mysql -e "CREATE DATABASE $DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    mysql -e "CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASSWORD';"
    mysql -e "GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';"
    mysql -e "GRANT SELECT ON mysql.time_zone_name TO '$DB_USER'@'localhost';"
    mysql -e "FLUSH PRIVILEGES;"
}

# Configuration du vhost Apache
configure_vhost() {
    cat > /etc/apache2/sites-available/glpi.conf <<EOF
<VirtualHost *:80>
    ServerName $DOMAIN_NAME
    DocumentRoot /var/www/glpi/
    
    <Directory /var/www/glpi/public>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/glpi-error.log
    CustomLog \${APACHE_LOG_DIR}/glpi-access.log combined
</VirtualHost>
EOF

    a2dissite 000-default.conf
    a2ensite glpi.conf
    systemctl reload apache2
    
    a2enmod rewrite
    systemctl restart apache2
}

# Configuration de PHP
configure_php() {
    # Configuration de PHP pour améliorer la sécurité et les performances
    for php_conf in /etc/php/*/apache2/php.ini; do
        sed -i 's/;session.cookie_httponly =/session.cookie_httponly = On/' "$php_conf"
        sed -i 's/session.cookie_httponly = Off/session.cookie_httponly = On/' "$php_conf"
        sed -i 's/memory_limit = .*/memory_limit = 256M/' "$php_conf"
        sed -i 's/max_execution_time = .*/max_execution_time = 300/' "$php_conf"
        sed -i 's/;opcache.enable=.*/opcache.enable=1/' "$php_conf"
    done
    systemctl restart apache2
}

# Configuration de la post-installation de GLPI
configure_glpi_post() {
    cd /var/www/glpi

    # Désactivation du mode strict pour permettre l'installation en CLI
    mysql -e "SET GLOBAL sql_mode = '';"

    # Attente que la base de données soit prête
    sleep 5

    # Mise à jour de la base de données
    php bin/console database:update --force --no-interaction || true

    # Activation des fuseaux horaires dans la base de données
    php bin/console database:enable_timezones --no-interaction

    # Vérification des prérequis système sans interaction
    php bin/console system:check_requirements --no-interaction

    # Exécution de l'installation via la ligne de commande en mode non-interactif
    php bin/console database:install \
        --db-host=$DB_HOST \
        --db-name=$DB_NAME \
        --db-user=$DB_USER \
        --db-password=$DB_PASSWORD \
        --db-port=$DB_PORT \
        --default-language=$LANGUAGE \
        --force \
        --no-telemetry \
        --no-interaction \
        --reconfigure \
        --strict-configuration

    # Configuration automatique sans interaction
    php bin/console glpi:config:set enable_telemetry 1 --no-interaction
    php bin/console glpi:config:set use_notifications 1 --no-interaction
    php bin/console glpi:config:set url_base "http://$DOMAIN_NAME" --no-interaction
    php bin/console maintenance:enable --no-interaction
    
    # Modification des mots de passe par défaut
    GLPI_PWD=$(openssl rand -base64 12)
    POST_PWD=$(openssl rand -base64 12)
    TECH_PWD=$(openssl rand -base64 12)
    NORMAL_PWD=$(openssl rand -base64 12)

    mysql -u $DB_USER -p$DB_PASSWORD $DB_NAME -e "UPDATE glpi_users SET password=SHA2('$GLPI_PWD',256) WHERE name='glpi';"
    mysql -u $DB_USER -p$DB_PASSWORD $DB_NAME -e "UPDATE glpi_users SET password=SHA2('$POST_PWD',256) WHERE name='post-only';"
    mysql -u $DB_USER -p$DB_PASSWORD $DB_NAME -e "UPDATE glpi_users SET password=SHA2('$TECH_PWD',256) WHERE name='tech';"
    mysql -u $DB_USER -p$DB_PASSWORD $DB_NAME -e "UPDATE glpi_users SET password=SHA2('$NORMAL_PWD',256) WHERE name='normal';"

    # Création du fichier de configuration des tâches cron
    echo "*/15 * * * * www-data cd /var/www/glpi && php front/cron.php" > /etc/cron.d/glpi
    chmod 644 /etc/cron.d/glpi
    
    # Sécurisation des fichiers
    chown -R www-data:www-data .
    find . -type f -exec chmod 644 {} \;
    find . -type d -exec chmod 755 {} \;

    # Suppression du fichier install.php pour des raisons de sécurité
    rm -f install/install.php

    # Désactivation du mode maintenance une fois la configuration terminée
    php bin/console maintenance:disable --no-interaction

    # Sauvegarde des nouveaux mots de passe dans un fichier sécurisé
    echo "Nouveaux mots de passe GLPI:" > /root/glpi_credentials.txt
    echo "glpi: $GLPI_PWD" >> /root/glpi_credentials.txt
    echo "post-only: $POST_PWD" >> /root/glpi_credentials.txt
    echo "tech: $TECH_PWD" >> /root/glpi_credentials.txt
    echo "normal: $NORMAL_PWD" >> /root/glpi_credentials.txt
    chmod 600 /root/glpi_credentials.txt
}

# Exécution principale
echo "Début de l'installation de GLPI..."

detect_distribution
install_dependencies
configure_php
install_glpi
configure_database
configure_vhost
configure_glpi_post

echo "Installation et configuration terminées!"
echo "Vous pouvez maintenant accéder à GLPI via http://$DOMAIN_NAME"
echo "Les mots de passe des utilisateurs ont été modifiés et sauvegardés dans /root/glpi_credentials.txt"
echo "Veuillez contacter votre administrateur système pour obtenir vos identifiants."
