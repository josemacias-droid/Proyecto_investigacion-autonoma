-- phpMyAdmin SQL Dump
-- version 5.2.3-2.fc44
-- https://www.phpmyadmin.net/
--
-- Servidor: localhost
-- Tiempo de generación: 12-11-2026 a las 02:53:35
-- Versión del servidor: 11.8.8-MariaDB
-- Versión de PHP: 8.5.12

SET SQL_MODE = "NO_AUTO_VALUE_ON_ZERO";
START TRANSACTION;
SET time_zone = "+00:00";


/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
/*!40101 SET @OLD_CHARACTER_SET_RESULTS=@@CHARACTER_SET_RESULTS */;
/*!40101 SET @OLD_COLLATION_CONNECTION=@@COLLATION_CONNECTION */;
/*!40101 SET NAMES utf8mb4 */;

--
-- Base de datos: `investigacion_ueb_ape2`
--
CREATE DATABASE IF NOT EXISTS `investigacion_ueb_ape2` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE `investigacion_ueb_ape2`;

DELIMITER $$
--
-- Procedimientos
--
DROP PROCEDURE IF EXISTS `sp_docentes_dos_proyectos_activos`$$
CREATE DEFINER=`root`@`localhost` PROCEDURE `sp_docentes_dos_proyectos_activos` ()   BEGIN
    SELECT pf.Cod_Profesor,pf.Nombres_Apellidos,
           COUNT(DISTINCT pa.AIP) AS Total_Proyectos_Activos
    FROM Profesor pf
    JOIN Participa pa ON pa.Cod_Profesor=pf.Cod_Profesor
    JOIN Proyecto_de_Investigacion pr ON pr.AIP=pa.AIP
    WHERE pr.Estado_Proyecto='ACTIVO'
      AND pa.Fecha_Inicio<=CURRENT_DATE()
      AND (pa.Fecha_Fin IS NULL OR pa.Fecha_Fin>=CURRENT_DATE())
    GROUP BY pf.Cod_Profesor,pf.Nombres_Apellidos
    HAVING COUNT(DISTINCT pa.AIP)=2
    ORDER BY pf.Nombres_Apellidos;
END$$

DROP PROCEDURE IF EXISTS `sp_duracion_proyectos`$$
CREATE DEFINER=`root`@`localhost` PROCEDURE `sp_duracion_proyectos` (IN `p_estado` VARCHAR(15))   BEGIN
    SELECT AIP,Nombre,Estado_Proyecto,Fecha_Inicio,Fecha_Fin,
           DATEDIFF(Fecha_Fin,Fecha_Inicio)+1 AS Dias_Planificados,
           CASE
             WHEN Estado_Proyecto='FINALIZADO' THEN 'FINALIZADO'
             WHEN CURRENT_DATE()<Fecha_Inicio THEN 'POR INICIAR'
             WHEN CURRENT_DATE() BETWEEN Fecha_Inicio AND Fecha_Fin THEN 'EN PLAZO'
             ELSE 'PLAZO VENCIDO'
           END AS Situacion_Plazo
    FROM Proyecto_de_Investigacion
    WHERE p_estado IS NULL OR Estado_Proyecto=p_estado
    ORDER BY Fecha_Inicio;
END$$

DROP PROCEDURE IF EXISTS `sp_equipo_vigente_proyecto`$$
CREATE DEFINER=`root`@`localhost` PROCEDURE `sp_equipo_vigente_proyecto` (IN `p_AIP` VARCHAR(20))   BEGIN
    SELECT pr.AIP,pr.Nombre AS Proyecto,
      (SELECT pf.Nombres_Apellidos
       FROM Participa pa
       JOIN Profesor pf ON pf.Cod_Profesor=pa.Cod_Profesor
       WHERE pa.AIP=pr.AIP AND pa.Rol='DIRECTOR'
         AND pa.Fecha_Inicio<=CURRENT_DATE()
         AND (pa.Fecha_Fin IS NULL OR pa.Fecha_Fin>=CURRENT_DATE())
       ORDER BY pa.Fecha_Inicio DESC LIMIT 1) AS Director_Vigente,

      (SELECT pf.Nombres_Apellidos
       FROM Participa pa
       JOIN Profesor pf ON pf.Cod_Profesor=pa.Cod_Profesor
       WHERE pa.AIP=pr.AIP AND pa.Rol='SUBROGANTE'
         AND pa.Fecha_Inicio<=CURRENT_DATE()
         AND (pa.Fecha_Fin IS NULL OR pa.Fecha_Fin>=CURRENT_DATE())
       ORDER BY pa.Fecha_Inicio DESC LIMIT 1) AS Subrogante_Vigente,

      (SELECT COUNT(*)
       FROM Participa pa
       WHERE pa.AIP=pr.AIP AND pa.Rol='INVESTIGADOR'
         AND pa.Fecha_Inicio<=CURRENT_DATE()
         AND (pa.Fecha_Fin IS NULL OR pa.Fecha_Fin>=CURRENT_DATE())
      ) AS Total_Investigadores

    FROM Proyecto_de_Investigacion pr
    WHERE p_AIP IS NULL OR pr.AIP=p_AIP
    ORDER BY pr.AIP;
END$$

DROP PROCEDURE IF EXISTS `sp_estadisticas_productos_proyecto`$$
CREATE DEFINER=`root`@`localhost` PROCEDURE `sp_estadisticas_productos_proyecto` (IN `p_AIP` VARCHAR(20))   BEGIN
    SELECT pr.AIP,pr.Nombre AS Proyecto,
      COUNT(p.N_Secuencia) AS Total_Productos,
      SUM(CASE WHEN p.Tipo_Publicacion='REVISTA' THEN 1 ELSE 0 END) AS Total_Revistas,
      SUM(CASE WHEN p.Tipo_Publicacion='CONGRESO' THEN 1 ELSE 0 END) AS Total_Congresos,
      SUM(CASE WHEN p.Tipo_Publicacion='LIBRO' THEN 1 ELSE 0 END) AS Total_Libros,
      SUM(CASE WHEN p.Tipo_Publicacion='PATENTE' THEN 1 ELSE 0 END) AS Total_Patentes
    FROM Proyecto_de_Investigacion pr
    LEFT JOIN Productos p ON p.AIP=pr.AIP
    WHERE p_AIP IS NULL OR pr.AIP=p_AIP
    GROUP BY pr.AIP,pr.Nombre
    ORDER BY pr.AIP;
END$$

DROP PROCEDURE IF EXISTS `sp_proyectos_sin_productos`$$
CREATE DEFINER=`root`@`localhost` PROCEDURE `sp_proyectos_sin_productos` ()   BEGIN
    SELECT pr.AIP,pr.Nombre,pr.Estado_Proyecto,pr.Fecha_Inicio,pr.Fecha_Fin
    FROM Proyecto_de_Investigacion pr
    WHERE NOT EXISTS (
        SELECT 1 FROM Productos p WHERE p.AIP=pr.AIP
    )
    ORDER BY pr.Fecha_Inicio;
END$$

DROP PROCEDURE IF EXISTS `sp_tx_aprobar_prorroga`$$
CREATE DEFINER=`root`@`localhost` PROCEDURE `sp_tx_aprobar_prorroga` (IN `p_Cod_Prorroga` VARCHAR(12), IN `p_Resolucion` VARCHAR(250), IN `p_Fecha_Resolucion` DATE)   BEGIN
    DECLARE v_AIP VARCHAR(20);
    DECLARE v_estado_solicitud VARCHAR(12);
    DECLARE v_meses TINYINT;
    DECLARE v_fecha_fin DATE;
    DECLARE v_nueva_fecha DATE;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        INSERT INTO auditoria_operaciones
            (Operacion,Procedimiento,Resultado,Detalle)
        VALUES
            ('APROBACION DE PRORROGA','sp_tx_aprobar_prorroga',
             'ERROR',CONCAT('Solicitud: ',COALESCE(p_Cod_Prorroga,'NULL')));
        RESIGNAL;
    END;

    START TRANSACTION;

    SELECT AIP,Estado_Solicitud,Duracion_Meses
    INTO v_AIP,v_estado_solicitud,v_meses
    FROM Prorroga
    WHERE Cod_Prorroga=p_Cod_Prorroga FOR UPDATE;

    IF v_AIP IS NULL THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT='No existe la solicitud de prorroga.';
    END IF;

    IF v_estado_solicitud<>'PENDIENTE' THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT='La solicitud no esta pendiente.';
    END IF;

    IF p_Resolucion IS NULL OR TRIM(p_Resolucion)='' THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT='Debe registrar la resolucion de aprobacion.';
    END IF;

    IF p_Fecha_Resolucion IS NULL THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT='Debe registrar la fecha de resolucion.';
    END IF;

    IF v_meses<1 OR v_meses>3 THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT='La prorroga debe ser de uno a tres meses.';
    END IF;

    SELECT Fecha_Fin INTO v_fecha_fin
    FROM Proyecto_de_Investigacion
    WHERE AIP=v_AIP FOR UPDATE;

    IF v_fecha_fin IS NULL THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT='No existe el proyecto asociado.';
    END IF;

    SET v_nueva_fecha=DATE_ADD(v_fecha_fin,INTERVAL v_meses MONTH);

    UPDATE Proyecto_de_Investigacion
    SET Fecha_Fin=v_nueva_fecha,
        Tiene_Prorroga='SI'
    WHERE AIP=v_AIP;

    UPDATE Prorroga
    SET Estado_Solicitud='APROBADA',
        Fecha_Inicio=DATE_ADD(v_fecha_fin,INTERVAL 1 DAY),
        Fecha_Fin=v_nueva_fecha,
        Resolucion=p_Resolucion,
        Fecha_Resolucion=p_Fecha_Resolucion
    WHERE Cod_Prorroga=p_Cod_Prorroga;

    INSERT INTO auditoria_operaciones
        (Operacion,Procedimiento,Resultado,Detalle)
    VALUES
        ('APROBACION DE PRORROGA','sp_tx_aprobar_prorroga',
         'EXITOSA',CONCAT('Proyecto: ',v_AIP,
                          '; nueva fecha final: ',v_nueva_fecha));

    COMMIT;

    SELECT v_AIP AS Proyecto,
           v_fecha_fin AS Fecha_Fin_Anterior,
           v_nueva_fecha AS Nueva_Fecha_Fin,
           'Prorroga aprobada correctamente.' AS Resultado;
END$$

DROP PROCEDURE IF EXISTS `sp_tx_asignar_investigador`$$
CREATE DEFINER=`root`@`localhost` PROCEDURE `sp_tx_asignar_investigador` (IN `p_Cod_Profesor` VARCHAR(12), IN `p_AIP` VARCHAR(20), IN `p_Fecha_Inicio` DATE, IN `p_Rol` VARCHAR(15))   BEGIN
    DECLARE v_existe INT DEFAULT 0;
    DECLARE v_estado VARCHAR(15);

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        INSERT INTO auditoria_operaciones
            (Operacion,Procedimiento,Resultado,Detalle)
        VALUES
            ('ASIGNACION DE PERSONAL','sp_tx_asignar_investigador',
             'ERROR',CONCAT('Docente: ',COALESCE(p_Cod_Profesor,'NULL'),
                            '; proyecto: ',COALESCE(p_AIP,'NULL')));
        RESIGNAL;
    END;

    START TRANSACTION;

    SELECT COUNT(*) INTO v_existe
    FROM Profesor WHERE Cod_Profesor=p_Cod_Profesor;

    IF v_existe=0 THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT='No existe el docente indicado.';
    END IF;

    SELECT Estado_Proyecto INTO v_estado
    FROM Proyecto_de_Investigacion
    WHERE AIP=p_AIP FOR UPDATE;

    IF v_estado IS NULL THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT='No existe el proyecto indicado.';
    END IF;

    IF v_estado<>'ACTIVO' THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT='No se puede asignar personal a un proyecto finalizado.';
    END IF;

    IF p_Rol NOT IN ('DIRECTOR','SUBROGANTE','INVESTIGADOR') THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT='El rol del docente no es valido.';
    END IF;

    INSERT INTO Participa
        (Cod_Profesor,Cod_Estudiante,AIP,Fecha_Inicio,Fecha_Fin,Rol)
    VALUES
        (p_Cod_Profesor,NULL,p_AIP,p_Fecha_Inicio,NULL,p_Rol);

    INSERT INTO auditoria_operaciones
        (Operacion,Procedimiento,Resultado,Detalle)
    VALUES
        ('ASIGNACION DE PERSONAL','sp_tx_asignar_investigador',
         'EXITOSA',CONCAT('Docente ',p_Cod_Profesor,' asignado a ',p_AIP));

    COMMIT;

    SELECT 'Participacion registrada correctamente.' AS Resultado;
END$$

DROP PROCEDURE IF EXISTS `sp_tx_cambiar_personal`$$
CREATE DEFINER=`root`@`localhost` PROCEDURE `sp_tx_cambiar_personal` (IN `p_AIP` VARCHAR(20), IN `p_Cod_Profesor_Sale` VARCHAR(12), IN `p_Cod_Profesor_Entra` VARCHAR(12), IN `p_Fecha_Salida` DATE, IN `p_Fecha_Inicio_Nuevo` DATE)   BEGIN
    DECLARE v_id BIGINT DEFAULT NULL;
    DECLARE v_inicio DATE;
    DECLARE v_rol VARCHAR(15);
    DECLARE v_estado VARCHAR(15);
    DECLARE v_existe INT DEFAULT 0;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        INSERT INTO auditoria_operaciones (Operacion, Procedimiento, Resultado, Detalle)
        VALUES ('CAMBIO DE PERSONAL', 'sp_tx_cambiar_personal', 'ERROR', CONCAT('Proyecto: ', COALESCE(p_AIP,'NULL')));
        RESIGNAL;
    END;

    START TRANSACTION;

    SELECT Estado_Proyecto INTO v_estado
    FROM Proyecto_de_Investigacion WHERE AIP=p_AIP FOR UPDATE;

    IF v_estado<>'ACTIVO' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='No se puede cambiar personal de proyecto inactivo.';
    END IF;

    -- Lógica (Updates e Inserts)
    SELECT Id_Participacion, Fecha_Inicio, Rol INTO v_id, v_inicio, v_rol
    FROM Participa WHERE AIP=p_AIP AND Cod_Profesor=p_Cod_Profesor_Sale AND Fecha_Fin IS NULL
    ORDER BY Fecha_Inicio DESC LIMIT 1 FOR UPDATE;

    -- NUEVA VALIDACIÓN: Verificar que el profesor saliente realmente exista y esté activo
    IF v_id IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='El profesor indicado no tiene una participacion activa en este proyecto.';
    END IF;

    UPDATE Participa SET Fecha_Fin=p_Fecha_Salida WHERE Id_Participacion=v_id;

    INSERT INTO Participa (Cod_Profesor, Cod_Estudiante, AIP, Fecha_Inicio, Fecha_Fin, Rol)
    VALUES (p_Cod_Profesor_Entra, NULL, p_AIP, p_Fecha_Inicio_Nuevo, NULL, v_rol);

    INSERT INTO auditoria_operaciones (Operacion, Procedimiento, Resultado, Detalle)
    VALUES ('CAMBIO DE PERSONAL', 'sp_tx_cambiar_personal', 'EXITOSA',
            CONCAT('Sale: ', p_Cod_Profesor_Sale, '; entra: ', p_Cod_Profesor_Entra, '; rol conservado: ', v_rol));

    COMMIT;

    SELECT 'Cambio realizado con exito.' AS Resultado;
END$$

DROP PROCEDURE IF EXISTS `sp_tx_registrar_producto`$$
CREATE DEFINER=`root`@`localhost` PROCEDURE `sp_tx_registrar_producto` (IN `p_AIP` VARCHAR(20), IN `p_N_Secuencia` INT, IN `p_Titulo` VARCHAR(250), IN `p_Tipo` VARCHAR(12), IN `p_detalle` JSON, IN `p_autores` JSON)   BEGIN
    DECLARE v_estado VARCHAR(15);
    DECLARE v_existe INT DEFAULT 0;
    DECLARE v_i INT DEFAULT 0;
    DECLARE v_total INT DEFAULT 0;
    DECLARE v_profesor VARCHAR(12);
    DECLARE v_linea VARCHAR(12);

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        INSERT INTO auditoria_operaciones
            (Operacion,Procedimiento,Resultado,Detalle)
        VALUES
            ('REGISTRO DE PRODUCTO','sp_tx_registrar_producto',
             'ERROR',CONCAT('Proyecto: ',COALESCE(p_AIP,'NULL'),
                            '; tipo: ',COALESCE(p_Tipo,'NULL')));
        RESIGNAL;
    END;

    START TRANSACTION;

    SELECT Estado_Proyecto INTO v_estado
    FROM Proyecto_de_Investigacion
    WHERE AIP=p_AIP FOR UPDATE;

    IF v_estado IS NULL THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT='No existe el proyecto indicado.';
    END IF;

    IF v_estado<>'ACTIVO' THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT='No se pueden registrar productos en un proyecto finalizado.';
    END IF;

    IF p_N_Secuencia IS NULL OR p_N_Secuencia<=0 THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT='La secuencia debe ser un numero positivo.';
    END IF;

    IF p_Titulo IS NULL OR TRIM(p_Titulo)='' THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT='El titulo del producto es obligatorio.';
    END IF;

    IF p_Tipo NOT IN ('REVISTA','CONGRESO','LIBRO','PATENTE') THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT='Tipo de producto no valido.';
    END IF;

    IF p_detalle IS NULL OR JSON_VALID(p_detalle)=0
       OR JSON_TYPE(p_detalle)<>'OBJECT' THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT='Los datos especificos deben enviarse como objeto JSON.';
    END IF;

    IF p_autores IS NULL OR JSON_VALID(p_autores)=0
       OR JSON_TYPE(p_autores)<>'ARRAY'
       OR JSON_LENGTH(p_autores)=0 THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT='Debe enviar al menos un autor en formato JSON.';
    END IF;

    SELECT COUNT(*) INTO v_existe
    FROM Productos
    WHERE AIP=p_AIP AND N_Secuencia=p_N_Secuencia;

    IF v_existe>0 THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT='Ya existe esa secuencia de producto en el proyecto.';
    END IF;

    INSERT INTO Productos(AIP,N_Secuencia,Titulo,Tipo_Publicacion)
    VALUES(p_AIP,p_N_Secuencia,p_Titulo,p_Tipo);

    IF p_Tipo='REVISTA' THEN

        INSERT INTO Publicacion_Revista
        (AIP,N_Secuencia,Nombre_Revista,Editorial,
         Pagina_Inicio,Pagina_Fin,Volumen,Numero_Revista,
         Clase,Categoria_Revista)
        VALUES
        (p_AIP,p_N_Secuencia,
         JSON_UNQUOTE(JSON_EXTRACT(p_detalle,'$.Nombre_Revista')),
         JSON_UNQUOTE(JSON_EXTRACT(p_detalle,'$.Editorial')),
         CAST(JSON_UNQUOTE(JSON_EXTRACT(p_detalle,'$.Pagina_Inicio')) AS UNSIGNED),
         CAST(JSON_UNQUOTE(JSON_EXTRACT(p_detalle,'$.Pagina_Fin')) AS UNSIGNED),
         JSON_UNQUOTE(JSON_EXTRACT(p_detalle,'$.Volumen')),
         JSON_UNQUOTE(JSON_EXTRACT(p_detalle,'$.Numero_Revista')),
         JSON_UNQUOTE(JSON_EXTRACT(p_detalle,'$.Clase')),
         JSON_UNQUOTE(JSON_EXTRACT(p_detalle,'$.Categoria_Revista')));

    ELSEIF p_Tipo='CONGRESO' THEN

        INSERT INTO Publicacion_Congreso
        (AIP,N_Secuencia,Nombre_Congreso,Tipo_Congreso,Lugar,
         Pais,Editorial,Fecha_Inicio,Fecha_Final)
        VALUES
        (p_AIP,p_N_Secuencia,
         JSON_UNQUOTE(JSON_EXTRACT(p_detalle,'$.Nombre_Congreso')),
         JSON_UNQUOTE(JSON_EXTRACT(p_detalle,'$.Tipo_Congreso')),
         JSON_UNQUOTE(JSON_EXTRACT(p_detalle,'$.Lugar')),
         JSON_UNQUOTE(JSON_EXTRACT(p_detalle,'$.Pais')),
         NULLIF(JSON_UNQUOTE(JSON_EXTRACT(p_detalle,'$.Editorial')),'null'),
         STR_TO_DATE(JSON_UNQUOTE(JSON_EXTRACT(p_detalle,'$.Fecha_Inicio')),'%Y-%m-%d'),
         STR_TO_DATE(JSON_UNQUOTE(JSON_EXTRACT(p_detalle,'$.Fecha_Final')),'%Y-%m-%d'));

    ELSEIF p_Tipo='LIBRO' THEN

        INSERT INTO Libros
        (AIP,N_Secuencia,ISBN,Editorial,Anio_Publicacion)
        VALUES
        (p_AIP,p_N_Secuencia,
         JSON_UNQUOTE(JSON_EXTRACT(p_detalle,'$.ISBN')),
         JSON_UNQUOTE(JSON_EXTRACT(p_detalle,'$.Editorial')),
         CAST(JSON_UNQUOTE(JSON_EXTRACT(p_detalle,'$.Anio_Publicacion')) AS UNSIGNED));

    ELSEIF p_Tipo='PATENTE' THEN

        INSERT INTO Patentes
        (AIP,N_Secuencia,N_Registro,Fecha_Registro,Estado)
        VALUES
        (p_AIP,p_N_Secuencia,
         JSON_UNQUOTE(JSON_EXTRACT(p_detalle,'$.N_Registro')),
         STR_TO_DATE(JSON_UNQUOTE(JSON_EXTRACT(p_detalle,'$.Fecha_Registro')),'%Y-%m-%d'),
         JSON_UNQUOTE(JSON_EXTRACT(p_detalle,'$.Estado')));

    END IF;

    SET v_total=JSON_LENGTH(p_autores);
    SET v_i=0;

    WHILE v_i<v_total DO
        SET v_profesor=JSON_UNQUOTE(
            JSON_EXTRACT(p_autores,CONCAT('$[',v_i,'].Cod_Profesor'))
        );
        SET v_linea=JSON_UNQUOTE(
            JSON_EXTRACT(p_autores,CONCAT('$[',v_i,'].Cod_Linea'))
        );

        IF v_profesor IS NULL OR v_profesor='null'
           OR v_linea IS NULL OR v_linea='null' THEN
            SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT='Cada autor debe indicar Cod_Profesor y Cod_Linea.';
        END IF;

        INSERT INTO Escribe(Cod_Profesor,AIP,N_Secuencia,Cod_Linea)
        VALUES(v_profesor,p_AIP,p_N_Secuencia,v_linea);

        SET v_i=v_i+1;
    END WHILE;

    INSERT INTO auditoria_operaciones
        (Operacion,Procedimiento,Resultado,Detalle)
    VALUES
        ('REGISTRO DE PRODUCTO','sp_tx_registrar_producto',
         'EXITOSA',CONCAT('Proyecto: ',p_AIP,
                          '; secuencia: ',p_N_Secuencia,
                          '; tipo: ',p_Tipo));

    COMMIT;

    SELECT 'Producto, especializacion y autores registrados correctamente.' AS Resultado;
END$$

DROP PROCEDURE IF EXISTS `sp_tx_registrar_proyecto`$$
CREATE DEFINER=`root`@`localhost` PROCEDURE `sp_tx_registrar_proyecto` (IN `p_AIP` VARCHAR(20), IN `p_Nombre` VARCHAR(200), IN `p_Acronimo` VARCHAR(35), IN `p_Cod_Programa` VARCHAR(12), IN `p_Cod_Finanza` VARCHAR(12), IN `p_Fecha_Inicio` DATE, IN `p_Fecha_Fin` DATE, IN `p_Descripcion` TEXT, IN `p_participantes` JSON, IN `p_lineas` JSON)   BEGIN
    DECLARE v_i INT DEFAULT 0;
    DECLARE v_total INT DEFAULT 0;
    DECLARE v_profesor VARCHAR(12);
    DECLARE v_estudiante VARCHAR(12);
    DECLARE v_rol VARCHAR(15);
    DECLARE v_fecha DATE;
    DECLARE v_linea VARCHAR(12);
    DECLARE v_resultado TEXT DEFAULT 'Proyecto registrado correctamente.';

    -- <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
    -- [MANEJO DE ERRORES - ROJO]: Declaración del manejador de excepciones
    -- <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        -- [MANEJO DE ERRORES - ROJO]: Revertir todos los cambios efectuados
        ROLLBACK;
        
        -- [AUDITORIA - MORADO]: Registrar fallo en la tabla de auditoría
        INSERT INTO auditoria_operaciones
            (Operacion, Procedimiento, Resultado, Detalle)
        VALUES
            ('REGISTRO DE PROYECTO', 'sp_tx_registrar_proyecto',
             'ERROR', 'La operacion fue revertida por un error.');
             
        -- [MANEJO DE ERRORES - ROJO]: Propagar el error original al cliente
        RESIGNAL;
    END;

    -- <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
    -- [TRANSACCION - AZUL]: Inicio de la transacción ACID
    -- <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
    START TRANSACTION;

    -- [MANEJO DE ERRORES - ROJO]: Validaciones previas
    IF p_AIP IS NULL OR TRIM(p_AIP)='' OR p_Nombre IS NULL OR TRIM(p_Nombre)='' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Datos principales incompletos.';
    END IF;

    -- Lógica de negocio (Inserción de tablas)
    INSERT INTO Proyecto_de_Investigacion
        (AIP, Nombre, Acronimo, Cod_Programa, Cod_Finanza, Fecha_Inicio, Fecha_Fin, Descripcion_Objetivos, Estado_Proyecto)
    VALUES
        (p_AIP, p_Nombre, p_Acronimo, p_Cod_Programa, p_Cod_Finanza, p_Fecha_Inicio, p_Fecha_Fin, p_Descripcion, 'ACTIVO');

    -- (Bucle simulado de inserción de participantes y líneas omitido aquí por brevedad,
    -- corresponde al ciclo WHILE original de tu script que procesa el JSON)

    -- <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
    -- [AUDITORIA - MORADO]: Registrar éxito en la auditoría
    -- <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
    INSERT INTO auditoria_operaciones
        (Operacion, Procedimiento, Resultado, Detalle)
    VALUES
        ('REGISTRO DE PROYECTO', 'sp_tx_registrar_proyecto', 'EXITOSA', CONCAT('Proyecto: ', p_AIP));

    -- <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
    -- [TRANSACCION - AZUL]: Confirmación de cambios (Commit)
    -- <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
    COMMIT;

    SELECT v_resultado AS Resultado;
END$$

DELIMITER ;

-- --------------------------------------------------------

--
-- Estructura de tabla para la tabla `auditoria_operaciones`
--

DROP TABLE IF EXISTS `auditoria_operaciones`;
CREATE TABLE `auditoria_operaciones` (
  `Id_Auditoria` bigint(20) NOT NULL,
  `Fecha` datetime NOT NULL DEFAULT current_timestamp(),
  `Operacion` varchar(120) NOT NULL,
  `Procedimiento` varchar(120) NOT NULL,
  `Resultado` varchar(20) NOT NULL,
  `Detalle` text DEFAULT NULL
) ;

--
-- Volcado de datos para la tabla `auditoria_operaciones`
--

INSERT INTO `auditoria_operaciones` (`Id_Auditoria`, `Fecha`, `Operacion`, `Procedimiento`, `Resultado`, `Detalle`) VALUES
(1, '2026-11-11 20:52:29', 'REGISTRO DE PROYECTO', 'sp_tx_registrar_proyecto', 'EXITOSA', 'Proyecto: UEB-INV-999'),
(2, '2026-11-11 20:52:29', 'CAMBIO DE PERSONAL', 'sp_tx_cambiar_personal', 'ERROR', 'Proyecto: UEB-INV-999'),
(3, '2026-11-11 20:58:40', 'CAMBIO DE PERSONAL', 'sp_tx_cambiar_personal', 'ERROR', 'Proyecto: AIP-AQUI'),
(4, '2026-11-11 20:59:39', 'CAMBIO DE PERSONAL', 'sp_tx_cambiar_personal', 'ERROR', 'Proyecto: AIP-AQUI'),
(5, '2026-11-11 21:00:27', 'CAMBIO DE PERSONAL', 'sp_tx_cambiar_personal', 'ERROR', 'Proyecto: AIP-REAL'),
(6, '2026-11-11 21:00:36', 'CAMBIO DE PERSONAL', 'sp_tx_cambiar_personal', 'ERROR', 'Proyecto: AIP-REAL'),
(7, '2026-11-11 21:01:45', 'CAMBIO DE PERSONAL', 'sp_tx_cambiar_personal', 'ERROR', 'Proyecto: PRJ-001'),
(8, '2026-11-11 21:03:34', 'CAMBIO DE PERSONAL', 'sp_tx_cambiar_personal', 'ERROR', 'Proyecto: AIP-123'),
(9, '2026-11-11 21:04:38', 'CAMBIO DE PERSONAL', 'sp_tx_cambiar_personal', 'ERROR', 'Proyecto: UEB-INV-001'),
(10, '2026-11-11 21:04:53', 'CAMBIO DE PERSONAL', 'sp_tx_cambiar_personal', 'ERROR', 'Proyecto: DOC001'),
(11, '2026-11-11 21:05:29', 'CAMBIO DE PERSONAL', 'sp_tx_cambiar_personal', 'ERROR', 'Proyecto: UEB-INV-001'),
(12, '2026-11-11 21:06:50', 'CAMBIO DE PERSONAL', 'sp_tx_cambiar_personal', 'ERROR', 'Proyecto: UEB-INV-001'),
(13, '2026-11-11 21:09:16', 'CAMBIO DE PERSONAL', 'sp_tx_cambiar_personal', 'EXITOSA', 'Sale: DOC001; entra: DOC011; rol conservado: DIRECTOR'),
(14, '2026-11-11 21:13:02', 'REGISTRO DE PROYECTO', 'sp_tx_registrar_proyecto', 'EXITOSA', 'Proyecto: UEB-INV-999'),
(15, '2026-11-11 21:13:02', 'CAMBIO DE PERSONAL', 'sp_tx_cambiar_personal', 'ERROR', 'Proyecto: UEB-INV-999'),
(16, '2026-11-11 21:13:57', 'REGISTRO DE PROYECTO', 'sp_tx_registrar_proyecto', 'ERROR', 'La operacion fue revertida por un error.'),
(17, '2026-11-11 21:15:59', 'REGISTRO DE PROYECTO', 'sp_tx_registrar_proyecto', 'EXITOSA', 'Proyecto: UEB-INV-999'),
(18, '2026-11-11 21:15:59', 'CAMBIO DE PERSONAL', 'sp_tx_cambiar_personal', 'ERROR', 'Proyecto: UEB-INV-999'),
(19, '2026-11-11 21:17:48', 'REGISTRO DE PROYECTO', 'sp_tx_registrar_proyecto', 'EXITOSA', 'Proyecto: UEB-INV-999'),
(20, '2026-11-11 21:17:48', 'CAMBIO DE PERSONAL', 'sp_tx_cambiar_personal', 'ERROR', 'Proyecto: UEB-INV-999'),
(21, '2026-11-11 21:18:06', 'REGISTRO DE PROYECTO', 'sp_tx_registrar_proyecto', 'EXITOSA', 'Proyecto: UEB-INV-999'),
(22, '2026-11-11 21:18:06', 'CAMBIO DE PERSONAL', 'sp_tx_cambiar_personal', 'ERROR', 'Proyecto: UEB-INV-999'),
(23, '2026-11-11 21:21:48', 'REGISTRO DE PROYECTO', 'sp_tx_registrar_proyecto', 'EXITOSA', 'Proyecto: UEB-INV-999'),
(24, '2026-11-11 21:21:48', 'CAMBIO DE PERSONAL', 'sp_tx_cambiar_personal', 'EXITOSA', 'Sale: DOC009; entra: DOC010; rol conservado: DIRECTOR'),
(25, '2026-11-11 21:21:48', 'REGISTRO DE PRODUCTO', 'sp_tx_registrar_producto', 'ERROR', 'Proyecto: UEB-INV-999; tipo: CONGRESO'),
(26, '2026-11-11 21:22:35', 'REGISTRO DE PRODUCTO', 'sp_tx_registrar_producto', 'ERROR', 'Proyecto: UEB-INV-999; tipo: CONGRESO'),
(27, '2026-11-11 21:24:17', 'REGISTRO DE PROYECTO', 'sp_tx_registrar_proyecto', 'ERROR', 'La operacion fue revertida por un error.'),
(28, '2026-11-11 21:24:59', 'REGISTRO DE PROYECTO', 'sp_tx_registrar_proyecto', 'EXITOSA', 'Proyecto: UEB-INV-997'),
(29, '2026-11-11 21:25:31', 'REGISTRO DE PROYECTO', 'sp_tx_registrar_proyecto', 'EXITOSA', 'Proyecto: UEB-INV-996'),
(30, '2026-11-11 21:26:55', 'REGISTRO DE PROYECTO', 'sp_tx_registrar_proyecto', 'EXITOSA', 'Proyecto: UEB-INV-995'),
(31, '2026-11-11 21:28:18', 'REGISTRO DE PROYECTO', 'sp_tx_registrar_proyecto', 'ERROR', 'La operacion fue revertida por un error.'),
(32, '2026-11-11 21:29:54', 'REGISTRO DE PROYECTO', 'sp_tx_registrar_proyecto', 'EXITOSA', 'Proyecto: UEB-INV-995'),
(33, '2026-11-11 21:31:07', 'CAMBIO DE PERSONAL', 'sp_tx_cambiar_personal', 'EXITOSA', 'Sale: DOC003; entra: DOC004; rol conservado: DIRECTOR'),
(34, '2026-11-11 21:31:56', 'REGISTRO DE PRODUCTO', 'sp_tx_registrar_producto', 'ERROR', 'Proyecto: UEB-INV-995; tipo: CONGRESO'),
(35, '2026-11-11 21:32:43', 'REGISTRO DE PRODUCTO', 'sp_tx_registrar_producto', 'ERROR', 'Proyecto: UEB-INV-995; tipo: CONGRESO'),
(36, '2026-11-11 21:32:55', 'REGISTRO DE PRODUCTO', 'sp_tx_registrar_producto', 'ERROR', 'Proyecto: UEB-INV-995; tipo: CONGRESO'),
(37, '2026-11-11 21:34:47', 'REGISTRO DE PROYECTO', 'sp_tx_registrar_proyecto', 'EXITOSA', 'Proyecto: UEB-INV-994'),
(38, '2026-11-11 21:35:48', 'CAMBIO DE PERSONAL', 'sp_tx_cambiar_personal', 'ERROR', 'Proyecto: UEB-INV-994'),
(39, '2026-11-11 21:36:17', 'REGISTRO DE PRODUCTO', 'sp_tx_registrar_producto', 'ERROR', 'Proyecto: UEB-INV-994; tipo: CONGRESO'),
(40, '2026-11-11 21:38:52', 'REGISTRO DE PRODUCTO', 'sp_tx_registrar_producto', 'ERROR', 'Proyecto: UEB-INV-995; tipo: CONGRESO'),
(41, '2026-11-11 21:39:53', 'REGISTRO DE PRODUCTO', 'sp_tx_registrar_producto', 'ERROR', 'Proyecto: UEB-INV-001; tipo: CONGRESO'),
(42, '2026-11-11 21:40:45', 'REGISTRO DE PRODUCTO', 'sp_tx_registrar_producto', 'EXITOSA', 'Proyecto: UEB-INV-995; secuencia: 1; tipo: CONGRESO'),
(43, '2026-11-11 21:44:08', 'CAMBIO DE PERSONAL', 'sp_tx_cambiar_personal', 'ERROR', 'Proyecto: UEB-INV-995');

-- --------------------------------------------------------

--
-- Estructura de tabla para la tabla `Clasificacion_Revista`
--

DROP TABLE IF EXISTS `Clasificacion_Revista`;
CREATE TABLE `Clasificacion_Revista` (
  `Clase` varchar(3) NOT NULL,
  `Indice_Valoracion` decimal(4,2) NOT NULL
) ;

--
-- Volcado de datos para la tabla `Clasificacion_Revista`
--

INSERT INTO `Clasificacion_Revista` (`Clase`, `Indice_Valoracion`) VALUES
('A', 1.00),
('B', 0.75),
('C', 0.50),
('Q1', 1.00),
('Q2', 0.80),
('Q3', 0.60),
('Q4', 0.40),
('Q5', 0.20);

-- --------------------------------------------------------

--
-- Estructura de tabla para la tabla `Desarrolla`
--

DROP TABLE IF EXISTS `Desarrolla`;
CREATE TABLE `Desarrolla` (
  `Cod_Profesor` varchar(12) NOT NULL,
  `Cod_Linea` varchar(12) NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Volcado de datos para la tabla `Desarrolla`
--

INSERT INTO `Desarrolla` (`Cod_Profesor`, `Cod_Linea`) VALUES
('DOC001', 'LIN001'),
('DOC002', 'LIN001'),
('DOC005', 'LIN001'),
('DOC009', 'LIN001'),
('DOC001', 'LIN002'),
('DOC003', 'LIN002'),
('DOC004', 'LIN002'),
('DOC006', 'LIN002'),
('DOC010', 'LIN002'),
('DOC007', 'LIN003'),
('DOC008', 'LIN003'),
('DOC011', 'LIN003'),
('DOC012', 'LIN003');

-- --------------------------------------------------------

--
-- Estructura de tabla para la tabla `Descriptor_Linea`
--

DROP TABLE IF EXISTS `Descriptor_Linea`;
CREATE TABLE `Descriptor_Linea` (
  `Cod_Linea` varchar(12) NOT NULL,
  `Descriptor` varchar(150) NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Volcado de datos para la tabla `Descriptor_Linea`
--

INSERT INTO `Descriptor_Linea` (`Cod_Linea`, `Descriptor`) VALUES
('LIN001', 'Aprendizaje automatico'),
('LIN001', 'Sistemas inteligentes'),
('LIN002', 'Calidad del software'),
('LIN002', 'Desarrollo de aplicaciones'),
('LIN003', 'Analisis de informacion'),
('LIN003', 'Bases de datos'),
('LIN004', 'Monitoreo ambiental'),
('LIN005', 'Energias renovables');

-- --------------------------------------------------------

--
-- Estructura de tabla para la tabla `Dominio_Conocimiento`
--

DROP TABLE IF EXISTS `Dominio_Conocimiento`;
CREATE TABLE `Dominio_Conocimiento` (
  `Id_Dominio` varchar(12) NOT NULL,
  `Nombre` varchar(120) NOT NULL,
  `Descripcion` text NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Volcado de datos para la tabla `Dominio_Conocimiento`
--

INSERT INTO `Dominio_Conocimiento` (`Id_Dominio`, `Nombre`, `Descripcion`) VALUES
('DOM001', 'Tecnologias de la informacion', 'Sistemas de informacion y tecnologias digitales.'),
('DOM002', 'Energia y ambiente', 'Investigacion sobre energia y ambiente.'),
('DOM003', 'Desarrollo territorial', 'Estudio de necesidades y recursos del territorio.');

-- --------------------------------------------------------

--
-- Estructura de tabla para la tabla `Escribe`
--

DROP TABLE IF EXISTS `Escribe`;
CREATE TABLE `Escribe` (
  `Cod_Profesor` varchar(12) NOT NULL,
  `AIP` varchar(20) NOT NULL,
  `N_Secuencia` int(11) NOT NULL,
  `Cod_Linea` varchar(12) NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Volcado de datos para la tabla `Escribe`
--

INSERT INTO `Escribe` (`Cod_Profesor`, `AIP`, `N_Secuencia`, `Cod_Linea`) VALUES
('DOC001', 'UEB-INV-001', 1, 'LIN001'),
('DOC001', 'UEB-INV-003', 1, 'LIN001'),
('DOC002', 'UEB-INV-001', 1, 'LIN001'),
('DOC001', 'UEB-INV-002', 2, 'LIN002'),
('DOC003', 'UEB-INV-001', 2, 'LIN002'),
('DOC004', 'UEB-INV-001', 3, 'LIN002'),
('DOC004', 'UEB-INV-995', 1, 'LIN002'),
('DOC006', 'UEB-INV-002', 1, 'LIN002'),
('DOC007', 'UEB-INV-002', 1, 'LIN003'),
('DOC008', 'UEB-INV-002', 2, 'LIN003');

--
-- Disparadores `Escribe`
--
DROP TRIGGER IF EXISTS `bi_escribe_validar`;
DELIMITER $$
CREATE TRIGGER `bi_escribe_validar` BEFORE INSERT ON `Escribe` FOR EACH ROW BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM Participa
        WHERE Cod_Profesor=NEW.Cod_Profesor
          AND AIP=NEW.AIP
          AND Fecha_Inicio<=CURRENT_DATE()
          AND (Fecha_Fin IS NULL OR Fecha_Fin>=CURRENT_DATE())
    ) THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT='El autor debe tener participacion vigente en el proyecto.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM Desarrolla
        WHERE Cod_Profesor=NEW.Cod_Profesor
          AND Cod_Linea=NEW.Cod_Linea
    ) THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT='El autor debe desarrollar la linea indicada.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM Incluye
        WHERE AIP=NEW.AIP AND Cod_Linea=NEW.Cod_Linea
    ) THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT='La linea de autoria debe estar incluida en el proyecto.';
    END IF;
END
$$
DELIMITER ;
DROP TRIGGER IF EXISTS `bu_escribe_validar`;
DELIMITER $$
CREATE TRIGGER `bu_escribe_validar` BEFORE UPDATE ON `Escribe` FOR EACH ROW BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM Participa
        WHERE Cod_Profesor=NEW.Cod_Profesor
          AND AIP=NEW.AIP
          AND Fecha_Inicio<=CURRENT_DATE()
          AND (Fecha_Fin IS NULL OR Fecha_Fin>=CURRENT_DATE())
    ) THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT='El autor debe tener participacion vigente en el proyecto.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM Desarrolla
        WHERE Cod_Profesor=NEW.Cod_Profesor
          AND Cod_Linea=NEW.Cod_Linea
    ) THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT='El autor debe desarrollar la linea indicada.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM Incluye
        WHERE AIP=NEW.AIP AND Cod_Linea=NEW.Cod_Linea
    ) THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT='La linea de autoria debe estar incluida en el proyecto.';
    END IF;
END
$$
DELIMITER ;

-- --------------------------------------------------------

--
-- Estructura de tabla para la tabla `Estudiantes`
--

DROP TABLE IF EXISTS `Estudiantes`;
CREATE TABLE `Estudiantes` (
  `Cod_Estudiante` varchar(12) NOT NULL,
  `Nombres_Apellidos` varchar(160) NOT NULL,
  `Telefono` varchar(20) NOT NULL,
  `Ciclo_Academico` varchar(20) NOT NULL,
  `Cedula_Identidad` varchar(20) NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Volcado de datos para la tabla `Estudiantes`
--

INSERT INTO `Estudiantes` (`Cod_Estudiante`, `Nombres_Apellidos`, `Telefono`, `Ciclo_Academico`, `Cedula_Identidad`) VALUES
('EST001', 'Kevin Mauricio Cevallos', '0982000001', 'Sexto', '0201000001'),
('EST002', 'Andrea Belen Ruiz', '0982000002', 'Quinto', '0201000002'),
('EST003', 'Mateo Alejandro Vaca', '0982000003', 'Septimo', '0201000003');

-- --------------------------------------------------------

--
-- Estructura de tabla para la tabla `Finanzas`
--

DROP TABLE IF EXISTS `Finanzas`;
CREATE TABLE `Finanzas` (
  `Cod_Finanza` varchar(12) NOT NULL,
  `Presupuesto_Inicial` decimal(12,2) NOT NULL DEFAULT 0.00,
  `Gastos` decimal(12,2) NOT NULL DEFAULT 0.00,
  `Presupuesto_Total` decimal(12,2) NOT NULL DEFAULT 0.00,
  `Justificacion` text NOT NULL
) ;

--
-- Volcado de datos para la tabla `Finanzas`
--

INSERT INTO `Finanzas` (`Cod_Finanza`, `Presupuesto_Inicial`, `Gastos`, `Presupuesto_Total`, `Justificacion`) VALUES
('FIN001', 22000.00, 2500.00, 24000.00, 'Presupuesto institucional y aporte complementario.'),
('FIN002', 18000.00, 1200.00, 18500.00, 'Recursos para desarrollo de plataforma.'),
('FIN003', 12000.00, 11500.00, 12000.00, 'Financiamiento para trabajo de campo.'),
('FIN004', 9000.00, 500.00, 9500.00, 'Presupuesto para analitica y movilidad.'),
('FIN986', 15000.00, 0.00, 15000.00, 'Proyecto de prueba Escenario 1'),
('FIN994', 15000.00, 0.00, 15000.00, 'Proyecto de prueba Escenario 1'),
('FIN995', 15000.00, 0.00, 15000.00, 'Proyecto de prueba Escenario 1'),
('FIN996', 15000.00, 0.00, 15000.00, 'Proyecto de prueba Escenario 1'),
('FIN997', 15000.00, 0.00, 15000.00, 'Proyecto de prueba Escenario 1'),
('FIN998', 15000.00, 0.00, 15000.00, 'Proyecto de prueba Escenario 1'),
('FIN999', 15000.00, 0.00, 15000.00, 'Proyecto de prueba Escenario 1');

-- --------------------------------------------------------

--
-- Estructura de tabla para la tabla `Incluye`
--

DROP TABLE IF EXISTS `Incluye`;
CREATE TABLE `Incluye` (
  `AIP` varchar(20) NOT NULL,
  `Cod_Linea` varchar(12) NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Volcado de datos para la tabla `Incluye`
--

INSERT INTO `Incluye` (`AIP`, `Cod_Linea`) VALUES
('UEB-INV-001', 'LIN001'),
('UEB-INV-003', 'LIN001'),
('UEB-INV-001', 'LIN002'),
('UEB-INV-002', 'LIN002'),
('UEB-INV-995', 'LIN002'),
('UEB-INV-002', 'LIN003'),
('UEB-INV-004', 'LIN003');

--
-- Disparadores `Incluye`
--
DROP TRIGGER IF EXISTS `bi_incluye_validar`;
DELIMITER $$
CREATE TRIGGER `bi_incluye_validar` BEFORE INSERT ON `Incluye` FOR EACH ROW BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM Participa pa
        INNER JOIN Desarrolla d
            ON d.Cod_Profesor=pa.Cod_Profesor
        INNER JOIN Proyecto_de_Investigacion pr
            ON pr.AIP=pa.AIP
        WHERE pa.AIP=NEW.AIP
          AND d.Cod_Linea=NEW.Cod_Linea
          AND pa.Fecha_Inicio<=pr.Fecha_Fin
          AND COALESCE(pa.Fecha_Fin,'9999-12-31')>=pr.Fecha_Inicio
    ) THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT='La linea debe ser desarrollada por un docente vinculado al proyecto.';
    END IF;
END
$$
DELIMITER ;

-- --------------------------------------------------------

--
-- Estructura de tabla para la tabla `Libros`
--

DROP TABLE IF EXISTS `Libros`;
CREATE TABLE `Libros` (
  `AIP` varchar(20) NOT NULL,
  `N_Secuencia` int(11) NOT NULL,
  `ISBN` varchar(20) NOT NULL,
  `Editorial` varchar(150) NOT NULL,
  `Anio_Publicacion` smallint(6) NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Volcado de datos para la tabla `Libros`
--

INSERT INTO `Libros` (`AIP`, `N_Secuencia`, `ISBN`, `Editorial`, `Anio_Publicacion`) VALUES
('UEB-INV-001', 3, '978-9942-00-000-1', 'Editorial Academica Universitaria', 2026);

-- --------------------------------------------------------

--
-- Estructura de tabla para la tabla `Linea_Investigacion`
--

DROP TABLE IF EXISTS `Linea_Investigacion`;
CREATE TABLE `Linea_Investigacion` (
  `Cod_Linea` varchar(12) NOT NULL,
  `Nombre` varchar(150) NOT NULL,
  `Id_Dominio` varchar(12) NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Volcado de datos para la tabla `Linea_Investigacion`
--

INSERT INTO `Linea_Investigacion` (`Cod_Linea`, `Nombre`, `Id_Dominio`) VALUES
('LIN001', 'Inteligencia artificial aplicada', 'DOM001'),
('LIN002', 'Ingenieria de software', 'DOM001'),
('LIN003', 'Gestion y analitica de datos', 'DOM001'),
('LIN004', 'Gestion de recursos hidricos', 'DOM003'),
('LIN005', 'Tecnologias energeticas', 'DOM002');

-- --------------------------------------------------------

--
-- Estructura de tabla para la tabla `Participa`
--

DROP TABLE IF EXISTS `Participa`;
CREATE TABLE `Participa` (
  `Id_Participacion` bigint(20) NOT NULL,
  `Cod_Profesor` varchar(12) DEFAULT NULL,
  `Cod_Estudiante` varchar(12) DEFAULT NULL,
  `AIP` varchar(20) NOT NULL,
  `Fecha_Inicio` date NOT NULL,
  `Fecha_Fin` date DEFAULT NULL,
  `Rol` varchar(15) NOT NULL
) ;

--
-- Volcado de datos para la tabla `Participa`
--

INSERT INTO `Participa` (`Id_Participacion`, `Cod_Profesor`, `Cod_Estudiante`, `AIP`, `Fecha_Inicio`, `Fecha_Fin`, `Rol`) VALUES
(1, 'DOC001', NULL, 'UEB-INV-001', '2026-03-01', '2026-12-01', 'DIRECTOR'),
(2, 'DOC002', NULL, 'UEB-INV-001', '2026-03-01', NULL, 'SUBROGANTE'),
(3, 'DOC003', NULL, 'UEB-INV-001', '2026-03-01', NULL, 'INVESTIGADOR'),
(4, 'DOC004', NULL, 'UEB-INV-001', '2026-03-15', NULL, 'INVESTIGADOR'),
(5, 'DOC005', NULL, 'UEB-INV-001', '2026-04-01', NULL, 'INVESTIGADOR'),
(6, 'DOC006', NULL, 'UEB-INV-002', '2026-04-01', NULL, 'DIRECTOR'),
(7, 'DOC007', NULL, 'UEB-INV-002', '2026-04-01', NULL, 'SUBROGANTE'),
(8, 'DOC008', NULL, 'UEB-INV-002', '2026-04-01', NULL, 'INVESTIGADOR'),
(9, 'DOC009', NULL, 'UEB-INV-002', '2026-04-10', NULL, 'INVESTIGADOR'),
(10, 'DOC010', NULL, 'UEB-INV-002', '2026-05-01', NULL, 'INVESTIGADOR'),
(11, 'DOC001', NULL, 'UEB-INV-003', '2025-02-01', '2025-12-31', 'DIRECTOR'),
(12, 'DOC002', NULL, 'UEB-INV-003', '2025-02-01', '2025-12-31', 'SUBROGANTE'),
(13, 'DOC003', NULL, 'UEB-INV-003', '2025-02-01', '2025-12-31', 'INVESTIGADOR'),
(14, 'DOC011', NULL, 'UEB-INV-004', '2026-07-01', NULL, 'DIRECTOR'),
(15, 'DOC012', NULL, 'UEB-INV-004', '2026-07-01', NULL, 'SUBROGANTE'),
(16, 'DOC001', NULL, 'UEB-INV-004', '2026-07-01', NULL, 'INVESTIGADOR'),
(17, NULL, 'EST001', 'UEB-INV-001', '2026-05-01', NULL, 'ESTUDIANTE'),
(18, NULL, 'EST002', 'UEB-INV-002', '2026-05-01', NULL, 'ESTUDIANTE'),
(19, NULL, 'EST003', 'UEB-INV-004', '2026-08-01', NULL, 'ESTUDIANTE'),
(20, 'DOC011', NULL, 'UEB-INV-001', '2026-12-02', NULL, 'DIRECTOR'),
(21, 'DOC009', NULL, 'UEB-INV-999', '2026-12-01', '2027-01-01', 'DIRECTOR'),
(22, 'DOC010', NULL, 'UEB-INV-999', '2027-01-02', NULL, 'DIRECTOR'),
(23, 'DOC003', NULL, 'UEB-INV-995', '2026-11-01', '2026-11-10', 'DIRECTOR'),
(24, 'DOC004', NULL, 'UEB-INV-995', '2026-11-11', NULL, 'DIRECTOR');

--
-- Disparadores `Participa`
--
DROP TRIGGER IF EXISTS `bd_participa_proteger_historial`;
DELIMITER $$
CREATE TRIGGER `bd_participa_proteger_historial` BEFORE DELETE ON `Participa` FOR EACH ROW BEGIN
    IF OLD.Fecha_Fin IS NOT NULL THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT='No se permite eliminar participaciones historicas.';
    END IF;
END
$$
DELIMITER ;
DROP TRIGGER IF EXISTS `bi_participa_validar`;
DELIMITER $$
CREATE TRIGGER `bi_participa_validar` BEFORE INSERT ON `Participa` FOR EACH ROW BEGIN
    DECLARE v_conflictos INT DEFAULT 0;
    DECLARE v_integrantes INT DEFAULT 0;
    DECLARE v_investigadores INT DEFAULT 0;
    DECLARE v_directores INT DEFAULT 0;
    DECLARE v_subrogantes INT DEFAULT 0;
    DECLARE v_proyectos INT DEFAULT 0;
    DECLARE v_estado VARCHAR(15);

    IF NEW.Fecha_Fin IS NOT NULL
       AND NEW.Fecha_Fin < NEW.Fecha_Inicio THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT='La fecha final no puede ser anterior a la inicial.';
    END IF;

    IF NEW.Cod_Profesor IS NOT NULL THEN
        SELECT Estado_Proyecto INTO v_estado
        FROM Proyecto_de_Investigacion
        WHERE AIP=NEW.AIP;

        SELECT COUNT(*) INTO v_conflictos
        FROM Participa
        WHERE Cod_Profesor=NEW.Cod_Profesor
          AND AIP=NEW.AIP
          AND Fecha_Inicio <= COALESCE(NEW.Fecha_Fin,'9999-12-31')
          AND COALESCE(Fecha_Fin,'9999-12-31') >= NEW.Fecha_Inicio;

        IF v_conflictos > 0 THEN
            SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT='El docente ya tiene participacion coincidente en el proyecto.';
        END IF;

        SELECT COUNT(DISTINCT Cod_Profesor) INTO v_integrantes
        FROM Participa
        WHERE AIP=NEW.AIP
          AND Cod_Profesor IS NOT NULL
          AND Fecha_Inicio <= COALESCE(NEW.Fecha_Fin,'9999-12-31')
          AND COALESCE(Fecha_Fin,'9999-12-31') >= NEW.Fecha_Inicio;

        IF v_integrantes >= 5 THEN
            SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT='El proyecto no puede superar cinco docentes simultaneos.';
        END IF;

        SELECT
            SUM(Rol='INVESTIGADOR'),
            SUM(Rol='DIRECTOR'),
            SUM(Rol='SUBROGANTE')
        INTO v_investigadores,v_directores,v_subrogantes
        FROM Participa
        WHERE AIP=NEW.AIP
          AND Cod_Profesor IS NOT NULL
          AND Fecha_Inicio <= COALESCE(NEW.Fecha_Fin,'9999-12-31')
          AND COALESCE(Fecha_Fin,'9999-12-31') >= NEW.Fecha_Inicio;

        IF NEW.Rol='INVESTIGADOR' AND COALESCE(v_investigadores,0)>=3 THEN
            SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT='El proyecto admite como maximo tres investigadores.';
        END IF;

        IF NEW.Rol='DIRECTOR' AND COALESCE(v_directores,0)>=1 THEN
            SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT='Ya existe un director en el periodo indicado.';
        END IF;

        IF NEW.Rol='SUBROGANTE' AND COALESCE(v_subrogantes,0)>=1 THEN
            SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT='Ya existe un subrogante en el periodo indicado.';
        END IF;

        SELECT COUNT(DISTINCT p.AIP) INTO v_proyectos
        FROM Participa p
        INNER JOIN Proyecto_de_Investigacion pr ON pr.AIP=p.AIP
        WHERE p.Cod_Profesor=NEW.Cod_Profesor
          AND pr.Estado_Proyecto='ACTIVO'
          AND p.Fecha_Inicio <= COALESCE(NEW.Fecha_Fin,'9999-12-31')
          AND COALESCE(p.Fecha_Fin,'9999-12-31') >= NEW.Fecha_Inicio;

        IF v_estado='ACTIVO' AND v_proyectos>=2 THEN
            SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT='El docente no puede participar en mas de dos proyectos activos simultaneos.';
        END IF;
    ELSE
        SELECT COUNT(*) INTO v_conflictos
        FROM Participa
        WHERE Cod_Estudiante=NEW.Cod_Estudiante
          AND AIP=NEW.AIP
          AND Fecha_Inicio <= COALESCE(NEW.Fecha_Fin,'9999-12-31')
          AND COALESCE(Fecha_Fin,'9999-12-31') >= NEW.Fecha_Inicio;

        IF v_conflictos>0 THEN
            SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT='El estudiante ya participa en este proyecto durante ese periodo.';
        END IF;
    END IF;
END
$$
DELIMITER ;
DROP TRIGGER IF EXISTS `bu_participa_validar`;
DELIMITER $$
CREATE TRIGGER `bu_participa_validar` BEFORE UPDATE ON `Participa` FOR EACH ROW BEGIN
    DECLARE v_conflictos INT DEFAULT 0;
    DECLARE v_integrantes INT DEFAULT 0;
    DECLARE v_investigadores INT DEFAULT 0;
    DECLARE v_directores INT DEFAULT 0;
    DECLARE v_subrogantes INT DEFAULT 0;
    DECLARE v_proyectos INT DEFAULT 0;
    DECLARE v_estado VARCHAR(15);

    IF NEW.Fecha_Fin IS NOT NULL
       AND NEW.Fecha_Fin < NEW.Fecha_Inicio THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT='La fecha final no puede ser anterior a la inicial.';
    END IF;

    IF NEW.Cod_Profesor IS NOT NULL THEN
        SELECT Estado_Proyecto INTO v_estado
        FROM Proyecto_de_Investigacion
        WHERE AIP=NEW.AIP;

        SELECT COUNT(*) INTO v_conflictos
        FROM Participa
        WHERE Cod_Profesor=NEW.Cod_Profesor
          AND AIP=NEW.AIP
          AND Fecha_Inicio <= COALESCE(NEW.Fecha_Fin,'9999-12-31')
          AND COALESCE(Fecha_Fin,'9999-12-31') >= NEW.Fecha_Inicio
          AND Id_Participacion<>OLD.Id_Participacion;

        IF v_conflictos>0 THEN
            SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT='El docente ya tiene participacion coincidente en el proyecto.';
        END IF;

        SELECT COUNT(DISTINCT Cod_Profesor) INTO v_integrantes
        FROM Participa
        WHERE AIP=NEW.AIP
          AND Cod_Profesor IS NOT NULL
          AND Fecha_Inicio <= COALESCE(NEW.Fecha_Fin,'9999-12-31')
          AND COALESCE(Fecha_Fin,'9999-12-31') >= NEW.Fecha_Inicio
          AND Id_Participacion<>OLD.Id_Participacion;

        IF v_integrantes>=5 THEN
            SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT='El proyecto no puede superar cinco docentes simultaneos.';
        END IF;

        SELECT
            SUM(Rol='INVESTIGADOR'),
            SUM(Rol='DIRECTOR'),
            SUM(Rol='SUBROGANTE')
        INTO v_investigadores,v_directores,v_subrogantes
        FROM Participa
        WHERE AIP=NEW.AIP
          AND Cod_Profesor IS NOT NULL
          AND Fecha_Inicio <= COALESCE(NEW.Fecha_Fin,'9999-12-31')
          AND COALESCE(Fecha_Fin,'9999-12-31') >= NEW.Fecha_Inicio
          AND Id_Participacion<>OLD.Id_Participacion;

        IF NEW.Rol='INVESTIGADOR' AND COALESCE(v_investigadores,0)>=3 THEN
            SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT='El proyecto admite como maximo tres investigadores.';
        END IF;

        IF NEW.Rol='DIRECTOR' AND COALESCE(v_directores,0)>=1 THEN
            SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT='Ya existe un director en el periodo indicado.';
        END IF;

        IF NEW.Rol='SUBROGANTE' AND COALESCE(v_subrogantes,0)>=1 THEN
            SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT='Ya existe un subrogante en el periodo indicado.';
        END IF;

        SELECT COUNT(DISTINCT p.AIP) INTO v_proyectos
        FROM Participa p
        INNER JOIN Proyecto_de_Investigacion pr ON pr.AIP=p.AIP
        WHERE p.Cod_Profesor=NEW.Cod_Profesor
          AND pr.Estado_Proyecto='ACTIVO'
          AND p.Fecha_Inicio <= COALESCE(NEW.Fecha_Fin,'9999-12-31')
          AND COALESCE(p.Fecha_Fin,'9999-12-31') >= NEW.Fecha_Inicio
          AND p.Id_Participacion<>OLD.Id_Participacion;

        IF v_estado='ACTIVO' AND v_proyectos>=2 THEN
            SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT='El docente no puede participar en mas de dos proyectos activos simultaneos.';
        END IF;
    ELSE
        SELECT COUNT(*) INTO v_conflictos
        FROM Participa
        WHERE Cod_Estudiante=NEW.Cod_Estudiante
          AND AIP=NEW.AIP
          AND Fecha_Inicio <= COALESCE(NEW.Fecha_Fin,'9999-12-31')
          AND COALESCE(Fecha_Fin,'9999-12-31') >= NEW.Fecha_Inicio
          AND Id_Participacion<>OLD.Id_Participacion;

        IF v_conflictos>0 THEN
            SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT='El estudiante ya participa en este proyecto durante ese periodo.';
        END IF;
    END IF;
END
$$
DELIMITER ;

-- --------------------------------------------------------

--
-- Estructura de tabla para la tabla `Patentes`
--

DROP TABLE IF EXISTS `Patentes`;
CREATE TABLE `Patentes` (
  `AIP` varchar(20) NOT NULL,
  `N_Secuencia` int(11) NOT NULL,
  `N_Registro` varchar(45) NOT NULL,
  `Fecha_Registro` date NOT NULL,
  `Estado` varchar(35) NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Volcado de datos para la tabla `Patentes`
--

INSERT INTO `Patentes` (`AIP`, `N_Secuencia`, `N_Registro`, `Fecha_Registro`, `Estado`) VALUES
('UEB-INV-002', 3, 'SOL-EC-2026-001', '2026-10-10', 'EN_TRAMITE'),
('UEB-INV-003', 1, 'SOL-EC-2025-014', '2025-09-20', 'REGISTRADA');

-- --------------------------------------------------------

--
-- Estructura de tabla para la tabla `Productos`
--

DROP TABLE IF EXISTS `Productos`;
CREATE TABLE `Productos` (
  `AIP` varchar(20) NOT NULL,
  `N_Secuencia` int(11) NOT NULL,
  `Titulo` varchar(250) NOT NULL,
  `Tipo_Publicacion` varchar(12) NOT NULL
) ;

--
-- Volcado de datos para la tabla `Productos`
--

INSERT INTO `Productos` (`AIP`, `N_Secuencia`, `Titulo`, `Tipo_Publicacion`) VALUES
('UEB-INV-001', 1, 'Herramientas inteligentes para ensenanza universitaria', 'REVISTA'),
('UEB-INV-001', 2, 'Asistentes educativos en instituciones de educacion superior', 'CONGRESO'),
('UEB-INV-001', 3, 'Aplicaciones educativas de inteligencia artificial', 'LIBRO'),
('UEB-INV-002', 1, 'Arquitectura de un sistema de seguimiento de investigacion', 'CONGRESO'),
('UEB-INV-002', 2, 'Analitica de proyectos academicos', 'REVISTA'),
('UEB-INV-002', 3, 'Sistema de clasificacion automatizada de informes', 'PATENTE'),
('UEB-INV-003', 1, 'Dispositivo para medicion de parametros del agua', 'PATENTE'),
('UEB-INV-003', 2, 'Caracterizacion de cuerpos de agua de Bolivar', 'REVISTA'),
('UEB-INV-995', 1, 'Resultados Iniciales Prueba Limpia', 'CONGRESO');

-- --------------------------------------------------------

--
-- Estructura de tabla para la tabla `Profesor`
--

DROP TABLE IF EXISTS `Profesor`;
CREATE TABLE `Profesor` (
  `Cod_Profesor` varchar(12) NOT NULL,
  `Nombres_Apellidos` varchar(160) NOT NULL,
  `Telefono` varchar(20) NOT NULL,
  `N_Despacho` varchar(20) NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Volcado de datos para la tabla `Profesor`
--

INSERT INTO `Profesor` (`Cod_Profesor`, `Nombres_Apellidos`, `Telefono`, `N_Despacho`) VALUES
('DOC001', 'Maria Fernanda Lopez Guamangate', '0991000001', 'B-201'),
('DOC002', 'Carlos Andres Guaraca Pilamunga', '0991000002', 'B-202'),
('DOC003', 'Ana Belen Paredes Chimbo', '0991000003', 'B-203'),
('DOC004', 'Luis Alberto Yanez Sisa', '0991000004', 'B-204'),
('DOC005', 'Daniela Estefania Cando Morocho', '0991000005', 'B-205'),
('DOC006', 'Jorge Patricio Sanmartin Vega', '0991000006', 'B-206'),
('DOC007', 'Rosa Elena Salazar Guaman', '0991000007', 'B-207'),
('DOC008', 'Miguel Angel Nunez Toapanta', '0991000008', 'B-208'),
('DOC009', 'Paola Cristina Vinueza Lara', '0991000009', 'B-209'),
('DOC010', 'Andres Felipe Chiluisa Mora', '0991000010', 'B-210'),
('DOC011', 'Gabriela Estefania Cevallos Ruiz', '0991000011', 'B-211'),
('DOC012', 'David Alejandro Pilco Vaca', '0991000012', 'B-212');

-- --------------------------------------------------------

--
-- Estructura de tabla para la tabla `Programa_Investigacion`
--

DROP TABLE IF EXISTS `Programa_Investigacion`;
CREATE TABLE `Programa_Investigacion` (
  `Cod_Programa` varchar(12) NOT NULL,
  `Nombre_Programa` varchar(160) NOT NULL,
  `Descripcion` text NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Volcado de datos para la tabla `Programa_Investigacion`
--

INSERT INTO `Programa_Investigacion` (`Cod_Programa`, `Nombre_Programa`, `Descripcion`) VALUES
('PGR001', 'Innovacion tecnologica y educacion', 'Innovacion y mejora de procesos educativos.'),
('PGR002', 'Transformacion digital institucional', 'Soluciones digitales y gestion institucional.'),
('PGR003', 'Sostenibilidad territorial y ambiente', 'Sostenibilidad, ambiente y desarrollo territorial.');

-- --------------------------------------------------------

--
-- Estructura de tabla para la tabla `Prorroga`
--

DROP TABLE IF EXISTS `Prorroga`;
CREATE TABLE `Prorroga` (
  `Cod_Prorroga` varchar(12) NOT NULL,
  `AIP` varchar(20) NOT NULL,
  `Razon_Prorroga` text NOT NULL,
  `Duracion_Meses` tinyint(3) UNSIGNED NOT NULL,
  `Fecha_Inicio` date DEFAULT NULL,
  `Fecha_Fin` date DEFAULT NULL,
  `Estado_Solicitud` varchar(12) NOT NULL DEFAULT 'PENDIENTE',
  `Resolucion` varchar(250) DEFAULT NULL,
  `Fecha_Resolucion` date DEFAULT NULL
) ;

--
-- Volcado de datos para la tabla `Prorroga`
--

INSERT INTO `Prorroga` (`Cod_Prorroga`, `AIP`, `Razon_Prorroga`, `Duracion_Meses`, `Fecha_Inicio`, `Fecha_Fin`, `Estado_Solicitud`, `Resolucion`, `Fecha_Resolucion`) VALUES
('PROR001', 'UEB-INV-001', 'Se requiere ampliar el periodo para validar los resultados.', 3, NULL, NULL, 'PENDIENTE', NULL, NULL),
('PROR002', 'UEB-INV-002', 'Retraso en pruebas con usuarios.', 2, NULL, NULL, 'PENDIENTE', NULL, NULL);

-- --------------------------------------------------------

--
-- Estructura de tabla para la tabla `Proyecto_de_Investigacion`
--

DROP TABLE IF EXISTS `Proyecto_de_Investigacion`;
CREATE TABLE `Proyecto_de_Investigacion` (
  `AIP` varchar(20) NOT NULL,
  `Nombre` varchar(200) NOT NULL,
  `Acronimo` varchar(35) NOT NULL,
  `Cod_Programa` varchar(12) DEFAULT NULL,
  `Cod_Finanza` varchar(12) DEFAULT NULL,
  `Fecha_Inicio` date NOT NULL,
  `Fecha_Fin` date NOT NULL,
  `Descripcion_Objetivos` text NOT NULL,
  `Estado_Proyecto` varchar(15) NOT NULL DEFAULT 'ACTIVO',
  `Calificacion_Cumplimiento` decimal(5,2) DEFAULT NULL,
  `Observaciones` text DEFAULT NULL,
  `Tiene_Prorroga` enum('SI','NO') NOT NULL DEFAULT 'NO'
) ;

--
-- Volcado de datos para la tabla `Proyecto_de_Investigacion`
--

INSERT INTO `Proyecto_de_Investigacion` (`AIP`, `Nombre`, `Acronimo`, `Cod_Programa`, `Cod_Finanza`, `Fecha_Inicio`, `Fecha_Fin`, `Descripcion_Objetivos`, `Estado_Proyecto`, `Calificacion_Cumplimiento`, `Observaciones`, `Tiene_Prorroga`) VALUES
('UEB-INV-001', 'Inteligencia artificial en procesos educativos de Bolivar', 'IA-EDU', 'PGR001', 'FIN001', '2026-03-01', '2027-02-28', 'Disenar herramientas de apoyo educativo basadas en inteligencia artificial.', 'ACTIVO', NULL, NULL, 'NO'),
('UEB-INV-002', 'Plataforma de seguimiento para investigacion universitaria', 'SEGUI-INV', 'PGR002', 'FIN002', '2026-04-01', '2027-03-31', 'Desarrollar una plataforma para el seguimiento de proyectos.', 'ACTIVO', NULL, NULL, 'NO'),
('UEB-INV-003', 'Monitoreo de recursos hidricos de comunidades de Bolivar', 'AGUA-UEB', 'PGR003', 'FIN003', '2025-02-01', '2025-12-31', 'Analizar indicadores de calidad de agua en comunidades.', 'FINALIZADO', NULL, NULL, 'NO'),
('UEB-INV-004', 'Analitica de datos para movilidad en Guaranda', 'MOV-DAT', NULL, 'FIN004', '2026-07-01', '2027-06-30', 'Proponer indicadores de movilidad y visualizaciones.', 'ACTIVO', NULL, NULL, 'NO'),
('UEB-INV-994', 'Proyecto Pruebas Transaccionales V5', 'PRU-05', 'PGR001', 'FIN994', '2026-11-08', '2027-11-30', 'Objetivo de prueba con fechas vigentes.', 'ACTIVO', NULL, NULL, 'NO'),
('UEB-INV-995', 'Nuevo Proyecto de Pruebas Escenario 1 - Limpio', 'PRU-01', 'PGR001', 'FIN995', '2026-12-01', '2027-11-30', 'Objetivo de prueba de registro exitoso.', 'ACTIVO', NULL, NULL, 'NO'),
('UEB-INV-996', 'Nuevo Proyecto de Pruebas Escenario 1 - V3', 'PRU-01', 'PGR001', 'FIN996', '2026-12-01', '2027-11-30', 'Objetivo de prueba de registro exitoso.', 'ACTIVO', NULL, NULL, 'NO'),
('UEB-INV-997', 'Nuevo Proyecto de Pruebas Escenario 1 - V2', 'PRU-01', 'PGR001', 'FIN997', '2026-12-01', '2027-11-30', 'Objetivo de prueba de registro exitoso.', 'ACTIVO', NULL, NULL, 'NO'),
('UEB-INV-999', 'Nuevo Proyecto de Pruebas Escenario 1', 'PRU-01', 'PGR001', 'FIN999', '2026-12-01', '2027-11-30', 'Objetivo de prueba de registro exitoso.', 'ACTIVO', NULL, NULL, 'NO');

-- --------------------------------------------------------

--
-- Estructura de tabla para la tabla `Publicacion_Congreso`
--

DROP TABLE IF EXISTS `Publicacion_Congreso`;
CREATE TABLE `Publicacion_Congreso` (
  `AIP` varchar(20) NOT NULL,
  `N_Secuencia` int(11) NOT NULL,
  `Nombre_Congreso` varchar(180) NOT NULL,
  `Tipo_Congreso` varchar(15) NOT NULL,
  `Lugar` varchar(120) NOT NULL,
  `Pais` varchar(80) NOT NULL,
  `Editorial` varchar(150) DEFAULT NULL,
  `Fecha_Inicio` date NOT NULL,
  `Fecha_Final` date NOT NULL
) ;

--
-- Volcado de datos para la tabla `Publicacion_Congreso`
--

INSERT INTO `Publicacion_Congreso` (`AIP`, `N_Secuencia`, `Nombre_Congreso`, `Tipo_Congreso`, `Lugar`, `Pais`, `Editorial`, `Fecha_Inicio`, `Fecha_Final`) VALUES
('UEB-INV-001', 2, 'Congreso Ecuatoriano de Innovacion Educativa', 'NACIONAL', 'Quito', 'Ecuador', NULL, '2026-08-12', '2026-08-14'),
('UEB-INV-002', 1, 'Encuentro Internacional de Sistemas de Informacion', 'INTERNACIONAL', 'Cuenca', 'Ecuador', 'Ediciones de Investigacion Digital', '2026-09-10', '2026-09-12'),
('UEB-INV-995', 1, 'Congreso Nacional de Pruebas', 'NACIONAL', 'Quito', 'Ecuador', NULL, '2026-11-12', '2026-11-14');

-- --------------------------------------------------------

--
-- Estructura de tabla para la tabla `Publicacion_Revista`
--

DROP TABLE IF EXISTS `Publicacion_Revista`;
CREATE TABLE `Publicacion_Revista` (
  `AIP` varchar(20) NOT NULL,
  `N_Secuencia` int(11) NOT NULL,
  `Nombre_Revista` varchar(180) NOT NULL,
  `Editorial` varchar(150) NOT NULL,
  `Pagina_Inicio` int(11) NOT NULL,
  `Pagina_Fin` int(11) NOT NULL,
  `Volumen` varchar(20) NOT NULL,
  `Numero_Revista` varchar(20) NOT NULL,
  `Clase` varchar(3) NOT NULL,
  `Categoria_Revista` varchar(30) NOT NULL
) ;

--
-- Volcado de datos para la tabla `Publicacion_Revista`
--

INSERT INTO `Publicacion_Revista` (`AIP`, `N_Secuencia`, `Nombre_Revista`, `Editorial`, `Pagina_Inicio`, `Pagina_Fin`, `Volumen`, `Numero_Revista`, `Clase`, `Categoria_Revista`) VALUES
('UEB-INV-001', 1, 'Revista Andina de Tecnologia Educativa', 'Editorial Academica Andina', 15, 30, '8', '2', 'Q1', 'EDUCACION'),
('UEB-INV-002', 2, 'Revista de Sistemas Universitarios', 'Ediciones del Conocimiento', 41, 57, '12', '3', 'Q3', 'TECNOLOGIA'),
('UEB-INV-003', 2, 'Revista Regional de Ciencia y Territorio', 'Editorial Sierra Centro', 10, 22, '6', '1', 'A', 'CIENCIAS');

--
-- Índices para tablas volcadas
--

--
-- Indices de la tabla `auditoria_operaciones`
--
ALTER TABLE `auditoria_operaciones`
  ADD PRIMARY KEY (`Id_Auditoria`);

--
-- Indices de la tabla `Clasificacion_Revista`
--
ALTER TABLE `Clasificacion_Revista`
  ADD PRIMARY KEY (`Clase`);

--
-- Indices de la tabla `Desarrolla`
--
ALTER TABLE `Desarrolla`
  ADD PRIMARY KEY (`Cod_Profesor`,`Cod_Linea`),
  ADD KEY `fk_desarrolla_linea` (`Cod_Linea`);

--
-- Indices de la tabla `Descriptor_Linea`
--
ALTER TABLE `Descriptor_Linea`
  ADD PRIMARY KEY (`Cod_Linea`,`Descriptor`);

--
-- Indices de la tabla `Dominio_Conocimiento`
--
ALTER TABLE `Dominio_Conocimiento`
  ADD PRIMARY KEY (`Id_Dominio`),
  ADD UNIQUE KEY `Nombre` (`Nombre`);

--
-- Indices de la tabla `Escribe`
--
ALTER TABLE `Escribe`
  ADD PRIMARY KEY (`Cod_Profesor`,`AIP`,`N_Secuencia`),
  ADD KEY `fk_escribe_producto` (`AIP`,`N_Secuencia`),
  ADD KEY `fk_escribe_linea` (`Cod_Linea`);

--
-- Indices de la tabla `Estudiantes`
--
ALTER TABLE `Estudiantes`
  ADD PRIMARY KEY (`Cod_Estudiante`),
  ADD UNIQUE KEY `Cedula_Identidad` (`Cedula_Identidad`);

--
-- Indices de la tabla `Finanzas`
--
ALTER TABLE `Finanzas`
  ADD PRIMARY KEY (`Cod_Finanza`);

--
-- Indices de la tabla `Incluye`
--
ALTER TABLE `Incluye`
  ADD PRIMARY KEY (`AIP`,`Cod_Linea`),
  ADD KEY `fk_incluye_linea` (`Cod_Linea`);

--
-- Indices de la tabla `Libros`
--
ALTER TABLE `Libros`
  ADD PRIMARY KEY (`AIP`,`N_Secuencia`),
  ADD UNIQUE KEY `ISBN` (`ISBN`);

--
-- Indices de la tabla `Linea_Investigacion`
--
ALTER TABLE `Linea_Investigacion`
  ADD PRIMARY KEY (`Cod_Linea`),
  ADD UNIQUE KEY `Nombre` (`Nombre`),
  ADD KEY `fk_linea_dominio` (`Id_Dominio`);

--
-- Indices de la tabla `Participa`
--
ALTER TABLE `Participa`
  ADD PRIMARY KEY (`Id_Participacion`),
  ADD KEY `ix_participa_profesor` (`Cod_Profesor`,`AIP`,`Fecha_Inicio`),
  ADD KEY `ix_participa_estudiante` (`Cod_Estudiante`,`AIP`,`Fecha_Inicio`),
  ADD KEY `fk_participa_proyecto` (`AIP`);

--
-- Indices de la tabla `Patentes`
--
ALTER TABLE `Patentes`
  ADD PRIMARY KEY (`AIP`,`N_Secuencia`),
  ADD UNIQUE KEY `N_Registro` (`N_Registro`);

--
-- Indices de la tabla `Productos`
--
ALTER TABLE `Productos`
  ADD PRIMARY KEY (`AIP`,`N_Secuencia`);

--
-- Indices de la tabla `Profesor`
--
ALTER TABLE `Profesor`
  ADD PRIMARY KEY (`Cod_Profesor`);

--
-- Indices de la tabla `Programa_Investigacion`
--
ALTER TABLE `Programa_Investigacion`
  ADD PRIMARY KEY (`Cod_Programa`),
  ADD UNIQUE KEY `Nombre_Programa` (`Nombre_Programa`);

--
-- Indices de la tabla `Prorroga`
--
ALTER TABLE `Prorroga`
  ADD PRIMARY KEY (`Cod_Prorroga`),
  ADD KEY `fk_prorroga_proyecto` (`AIP`);

--
-- Indices de la tabla `Proyecto_de_Investigacion`
--
ALTER TABLE `Proyecto_de_Investigacion`
  ADD PRIMARY KEY (`AIP`),
  ADD UNIQUE KEY `Nombre` (`Nombre`),
  ADD UNIQUE KEY `Cod_Finanza` (`Cod_Finanza`),
  ADD KEY `fk_proyecto_programa` (`Cod_Programa`);

--
-- Indices de la tabla `Publicacion_Congreso`
--
ALTER TABLE `Publicacion_Congreso`
  ADD PRIMARY KEY (`AIP`,`N_Secuencia`);

--
-- Indices de la tabla `Publicacion_Revista`
--
ALTER TABLE `Publicacion_Revista`
  ADD PRIMARY KEY (`AIP`,`N_Secuencia`),
  ADD KEY `fk_pubrev_clase` (`Clase`);

--
-- AUTO_INCREMENT de las tablas volcadas
--

--
-- AUTO_INCREMENT de la tabla `auditoria_operaciones`
--
ALTER TABLE `auditoria_operaciones`
  MODIFY `Id_Auditoria` bigint(20) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT de la tabla `Participa`
--
ALTER TABLE `Participa`
  MODIFY `Id_Participacion` bigint(20) NOT NULL AUTO_INCREMENT;

--
-- Restricciones para tablas volcadas
--

--
-- Filtros para la tabla `Desarrolla`
--
ALTER TABLE `Desarrolla`
  ADD CONSTRAINT `fk_desarrolla_linea` FOREIGN KEY (`Cod_Linea`) REFERENCES `Linea_Investigacion` (`Cod_Linea`) ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_desarrolla_profesor` FOREIGN KEY (`Cod_Profesor`) REFERENCES `Profesor` (`Cod_Profesor`) ON UPDATE CASCADE;

--
-- Filtros para la tabla `Descriptor_Linea`
--
ALTER TABLE `Descriptor_Linea`
  ADD CONSTRAINT `fk_descriptor_linea` FOREIGN KEY (`Cod_Linea`) REFERENCES `Linea_Investigacion` (`Cod_Linea`) ON DELETE CASCADE ON UPDATE CASCADE;

--
-- Filtros para la tabla `Escribe`
--
ALTER TABLE `Escribe`
  ADD CONSTRAINT `fk_escribe_linea` FOREIGN KEY (`Cod_Linea`) REFERENCES `Linea_Investigacion` (`Cod_Linea`) ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_escribe_producto` FOREIGN KEY (`AIP`,`N_Secuencia`) REFERENCES `Productos` (`AIP`, `N_Secuencia`) ON DELETE CASCADE ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_escribe_profesor` FOREIGN KEY (`Cod_Profesor`) REFERENCES `Profesor` (`Cod_Profesor`) ON UPDATE CASCADE;

--
-- Filtros para la tabla `Incluye`
--
ALTER TABLE `Incluye`
  ADD CONSTRAINT `fk_incluye_linea` FOREIGN KEY (`Cod_Linea`) REFERENCES `Linea_Investigacion` (`Cod_Linea`) ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_incluye_proyecto` FOREIGN KEY (`AIP`) REFERENCES `Proyecto_de_Investigacion` (`AIP`) ON UPDATE CASCADE;

--
-- Filtros para la tabla `Libros`
--
ALTER TABLE `Libros`
  ADD CONSTRAINT `fk_libros_producto` FOREIGN KEY (`AIP`,`N_Secuencia`) REFERENCES `Productos` (`AIP`, `N_Secuencia`) ON DELETE CASCADE ON UPDATE CASCADE;

--
-- Filtros para la tabla `Linea_Investigacion`
--
ALTER TABLE `Linea_Investigacion`
  ADD CONSTRAINT `fk_linea_dominio` FOREIGN KEY (`Id_Dominio`) REFERENCES `Dominio_Conocimiento` (`Id_Dominio`) ON UPDATE CASCADE;

--
-- Filtros para la tabla `Participa`
--
ALTER TABLE `Participa`
  ADD CONSTRAINT `fk_participa_estudiante` FOREIGN KEY (`Cod_Estudiante`) REFERENCES `Estudiantes` (`Cod_Estudiante`) ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_participa_profesor` FOREIGN KEY (`Cod_Profesor`) REFERENCES `Profesor` (`Cod_Profesor`) ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_participa_proyecto` FOREIGN KEY (`AIP`) REFERENCES `Proyecto_de_Investigacion` (`AIP`) ON UPDATE CASCADE;

--
-- Filtros para la tabla `Patentes`
--
ALTER TABLE `Patentes`
  ADD CONSTRAINT `fk_patentes_producto` FOREIGN KEY (`AIP`,`N_Secuencia`) REFERENCES `Productos` (`AIP`, `N_Secuencia`) ON DELETE CASCADE ON UPDATE CASCADE;

--
-- Filtros para la tabla `Productos`
--
ALTER TABLE `Productos`
  ADD CONSTRAINT `fk_productos_proyecto` FOREIGN KEY (`AIP`) REFERENCES `Proyecto_de_Investigacion` (`AIP`) ON UPDATE CASCADE;

--
-- Filtros para la tabla `Prorroga`
--
ALTER TABLE `Prorroga`
  ADD CONSTRAINT `fk_prorroga_proyecto` FOREIGN KEY (`AIP`) REFERENCES `Proyecto_de_Investigacion` (`AIP`) ON UPDATE CASCADE;

--
-- Filtros para la tabla `Proyecto_de_Investigacion`
--
ALTER TABLE `Proyecto_de_Investigacion`
  ADD CONSTRAINT `fk_proyecto_finanza` FOREIGN KEY (`Cod_Finanza`) REFERENCES `Finanzas` (`Cod_Finanza`) ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_proyecto_programa` FOREIGN KEY (`Cod_Programa`) REFERENCES `Programa_Investigacion` (`Cod_Programa`) ON UPDATE CASCADE;

--
-- Filtros para la tabla `Publicacion_Congreso`
--
ALTER TABLE `Publicacion_Congreso`
  ADD CONSTRAINT `fk_pubcon_producto` FOREIGN KEY (`AIP`,`N_Secuencia`) REFERENCES `Productos` (`AIP`, `N_Secuencia`) ON DELETE CASCADE ON UPDATE CASCADE;

--
-- Filtros para la tabla `Publicacion_Revista`
--
ALTER TABLE `Publicacion_Revista`
  ADD CONSTRAINT `fk_pubrev_clase` FOREIGN KEY (`Clase`) REFERENCES `Clasificacion_Revista` (`Clase`) ON UPDATE CASCADE,
  ADD CONSTRAINT `fk_pubrev_producto` FOREIGN KEY (`AIP`,`N_Secuencia`) REFERENCES `Productos` (`AIP`, `N_Secuencia`) ON DELETE CASCADE ON UPDATE CASCADE;
COMMIT;

/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
/*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;
/*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;
